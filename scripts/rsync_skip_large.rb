#!/usr/bin/env ruby
#
# rsync_skip_large.rb — rsync SOURCE to DEST, but skip any folder that
# directly contains a file larger than a size threshold. Both the
# oversized file's contents AND its immediate parent folder are excluded
# entirely from the transfer.
#
# This requires a pre-scan of SOURCE to find oversized files before rsync
# runs, so on very large trees this adds real scan time up front. That's
# the only way to know which folders to exclude ahead of the transfer.
#
# Usage:
#   ruby rsync_skip_large.rb SOURCE DEST [options] [-- extra rsync args]
#
# Options:
#   --threshold SIZE   Size threshold, e.g. 50G, 10G, 500M (default: 50G)
#   --dry-run          Pass -n to rsync (shows what would transfer, no changes)
#   --verbose          Pass an extra -v to rsync (-vv) for more per-file detail
#
# rsync always runs with -rv --info=progress2 --stats --no-compress
# --size-only --whole-file --inplace. Deliberately NOT -a: this doesn't try
# to preserve timestamps, permissions, or ownership, since the destination
# (e.g. a share on another box, an rclone remote) often won't grant the
# `media` user permission to set those. --size-only skips re-transferring a
# file based on its size alone, since timestamps aren't preserved to compare
# against. On failure, the exit code is looked up against rsync's documented
# meanings so errors are explained, not just printed as a bare number.
#
# Anything after a literal `--` is passed straight through to rsync
# (e.g. `--delete`, `--progress`, `--exclude=.DS_Store`).
#
# Example:
#   ruby rsync_skip_large.rb /mnt/data/ /mnt/backup/ --threshold 50G --dry-run
#   ruby rsync_skip_large.rb /mnt/data/ /mnt/backup/ --threshold 20G -- --delete --progress

require 'find'
require 'pathname'
require 'shellwords'

def usage!
  warn <<~USAGE
    Usage: #{$PROGRAM_NAME} SOURCE DEST [--threshold SIZE] [--dry-run] [--verbose] [-- extra rsync args]

      SOURCE             Source directory to copy from
      DEST               Destination directory to copy to
      --threshold SIZE   e.g. 50G, 10G, 500M (default: 50G)
      --dry-run          Pass -n to rsync (no changes made)
      --verbose          Pass an extra -v to rsync (-vv) for more detail

    Anything after a literal `--` is passed straight to rsync.
  USAGE
  exit 1
end

def to_bytes(str)
  return str.to_i if str =~ /\A\d+\z/

  if (m = str.match(/\A(\d+)([KkMmGgTt])\z/))
    num  = m[1].to_i
    unit = m[2].downcase
    mult = { 'k' => 1024, 'm' => 1024**2, 'g' => 1024**3, 't' => 1024**4 }[unit]
    return num * mult
  end

  warn "Error: could not parse threshold '#{str}'"
  exit 1
end

def human(bytes)
  units = %w[B K M G T P]
  size = bytes.to_f
  idx = 0
  while size >= 1024 && idx < units.length - 1
    size /= 1024
    idx += 1
  end
  idx.zero? ? "#{bytes}B" : format('%.1f%s', size, units[idx])
end

# ---- Parse arguments ----

usage! if ARGV.length < 2

source_arg = ARGV.shift
dest_arg   = ARGV.shift

threshold_str = '50G'
dry_run = false
verbose = false
extra_rsync_args = []

while (arg = ARGV.shift)
  case arg
  when '--threshold'
    threshold_str = ARGV.shift || usage!
  when '--dry-run'
    dry_run = true
  when '--verbose'
    verbose = true
  when '--'
    extra_rsync_args = ARGV.dup
    break
  else
    warn "Unknown argument: #{arg}"
    usage!
  end
end

source = File.expand_path(source_arg)
unless Dir.exist?(source)
  warn "Error: source '#{source_arg}' is not a directory"
  exit 1
end

threshold_bytes = to_bytes(threshold_str)
source_path = Pathname.new(source)

puts "Scanning '#{source}' for files larger than #{threshold_str} (#{human(threshold_bytes)}) ..."
puts

excluded_dirs = {}   # relative_dir_path => [ [filename, size], ... ]
excluded_root_files = [] # files directly in source root that exceed threshold

Find.find(source) do |path|
  next unless File.file?(path)

  size = File.size(path)
  next if size <= threshold_bytes

  file_path = Pathname.new(path)
  parent    = file_path.dirname
  rel_parent = parent.relative_path_from(source_path).to_s

  if rel_parent == '.'
    # The oversized file sits directly in the source root. Excluding "the
    # folder it's in" would mean excluding the entire source, which almost
    # certainly isn't intended — so just exclude the file itself instead.
    excluded_root_files << [file_path.relative_path_from(source_path).to_s, size]
  else
    excluded_dirs[rel_parent] ||= []
    excluded_dirs[rel_parent] << [file_path.basename.to_s, size]
  end
end

if excluded_dirs.empty? && excluded_root_files.empty?
  puts "No files over #{threshold_str} found. Proceeding with a normal rsync."
else
  puts "Folders that will be EXCLUDED (contain a file over #{threshold_str}):"
  excluded_dirs.each do |rel_dir, files|
    puts "  #{rel_dir}/"
    files.each { |name, size| puts "      -> #{name} (#{human(size)})" }
  end

  unless excluded_root_files.empty?
    puts
    puts "Files directly in the source root over #{threshold_str} (only the file itself is excluded,"
    puts "since excluding 'its folder' would mean excluding the whole source):"
    excluded_root_files.each { |name, size| puts "  #{name} (#{human(size)})" }
  end
end
puts

# ---- Build rsync command ----

exclude_args = []
excluded_dirs.each_key { |rel_dir| exclude_args << "--exclude=/#{rel_dir}/" }
excluded_root_files.each { |name, _| exclude_args << "--exclude=/#{name}" }

rsync_cmd = ['rsync', '-r', '-v', '-h', '--info=progress2', '--stats',
             '--no-compress', '--size-only', '--whole-file', '--inplace']
rsync_cmd << '-v' if verbose
rsync_cmd << '-n' if dry_run
rsync_cmd.concat(exclude_args)
rsync_cmd.concat(extra_rsync_args)

# Ensure source has a trailing slash so rsync copies its CONTENTS into dest,
# rather than creating a nested source-named folder inside dest.
source_for_rsync = source.end_with?('/') ? source : "#{source}/"
dest_for_rsync    = File.expand_path(dest_arg)

rsync_cmd << source_for_rsync
rsync_cmd << dest_for_rsync

puts "Running:"
puts "  #{rsync_cmd.map { |a| Shellwords.escape(a) }.join(' ')}"
puts

RSYNC_EXIT_CODES = {
  1  => 'Syntax or usage error',
  2  => 'Protocol incompatibility',
  3  => 'Errors selecting input/output files, dirs',
  4  => 'Requested action not supported',
  5  => 'Error starting client-server protocol',
  6  => 'Daemon unable to append to log-file',
  10 => 'Error in socket I/O',
  11 => 'Error in file I/O',
  12 => 'Error in rsync protocol data stream',
  13 => 'Errors with program diagnostics',
  14 => 'Error in IPC code',
  20 => 'Received SIGUSR1 or SIGINT',
  21 => 'Some error returned by waitpid()',
  22 => 'Error allocating core memory buffers',
  23 => 'Partial transfer due to error (see rsync output above for which files)',
  24 => 'Partial transfer due to vanished source files',
  25 => 'The --max-delete limit stopped deletions',
  30 => 'Timeout in data send/receive',
  35 => 'Timeout waiting for daemon connection',
}.freeze

success = system(*rsync_cmd)

unless success
  code = $?.exitstatus
  reason = RSYNC_EXIT_CODES[code]
  puts
  warn "rsync failed with exit code #{code}#{reason ? " (#{reason})" : ''}."
  exit(code || 1)
end