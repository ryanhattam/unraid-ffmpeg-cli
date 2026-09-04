#!/usr/bin/env ruby
# =============================================================================
# file_batch_analyse.rb — Run file_analyse.rb against every file in a
#                          directory, writing one config per file
# =============================================================================
# Scans a directory for source video files and runs file_analyse.rb once per
# file, writing "<basename>_config.yaml" next to it (matching the naming
# file_batch_encode.rb looks for). Files that already have a config are
# skipped by default — file_analyse.rb has no overwrite prompt of its own,
# so this script's skip-if-exists check is what keeps re-runs idempotent and
# stops a batch from silently clobbering a hand-tuned config.
#
# Usage:
#   ruby file_batch_analyse.rb --dir /media/movies
#   ruby file_batch_analyse.rb --dir /media/movies -- --crf 16 --preset medium
#   ruby file_batch_analyse.rb --dir /media/movies --overwrite
#
# Everything after `--` is forwarded verbatim to file_analyse.rb for every
# file (e.g. --crf, --preset). Do not pass --file or --output there — this
# script sets those per file.
#
# Options:
#   --dir PATH          Directory containing source video files (required)
#   --config-dir PATH   Directory to write *_config.yaml into (default: --dir)
#   --pattern GLOB       Glob (relative to --dir) for source files (default: *.mkv)
#   --overwrite           Re-analyse and overwrite files that already have a config
#   --stop-on-error       Abort the batch on the first failed file (default: continue)
#   --list-only            List matched files and their status, run nothing
# =============================================================================

require 'optparse'

module C
  RESET = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"
  RED = "\033[91m"; GREEN = "\033[92m"; YELLOW = "\033[93m"; CYAN = "\033[96m"; WHITE = "\033[97m"; BLUE = "\033[94m"
end

def c(text, *codes) = "#{codes.join}#{text}#{C::RESET}"
def log_ok(msg)     = puts(c("  ✓  #{msg}", C::GREEN))
def log_warn(msg)   = puts(c("  ⚠  #{msg}", C::YELLOW))
def log_info(msg)   = puts(c("  ℹ  #{msg}", C::BLUE))
def log_dim(msg)    = puts(c("     #{msg}", C::DIM))
def log_error(msg)  = (puts(c("  ✗  #{msg}", C::RED)); exit 1)
def log_section(t)  = puts("\n#{c("── #{t}", C::CYAN, C::BOLD)}")

options = { dir: nil, config_dir: nil, pattern: '*.mkv', overwrite: false, stop_on_error: false, list_only: false }

sep_index = ARGV.index('--')
own_args, forward_args = if sep_index
  [ARGV[0...sep_index], ARGV[(sep_index + 1)..]]
else
  [ARGV, []]
end

OptionParser.new do |opts|
  opts.banner = "Usage: ruby file_batch_analyse.rb --dir DIR [options] [-- ANALYSE_ARGS...]"
  opts.on('--dir PATH',        'Directory of source video files (required)') { |v| options[:dir] = v }
  opts.on('--config-dir PATH', 'Directory to write *_config.yaml into (default: --dir)') { |v| options[:config_dir] = v }
  opts.on('--pattern GLOB',    'Glob for source files (default: *.mkv)')     { |v| options[:pattern] = v }
  opts.on('--overwrite',       'Re-analyse files that already have a config') { options[:overwrite] = true }
  opts.on('--stop-on-error',   'Abort on first failed file')                { options[:stop_on_error] = true }
  opts.on('--list-only',       'List matched files and status, run nothing') { options[:list_only] = true }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!(own_args)

log_error("--dir is required") unless options[:dir]
log_error("Directory not found: #{options[:dir]}") unless Dir.exist?(options[:dir])

if (forward_args & ['--file', '--output']).any?
  log_error("Do not forward --file or --output — this script sets those per file")
end

DIR         = File.expand_path(options[:dir])
CONFIG_DIR  = options[:config_dir] ? File.expand_path(options[:config_dir]) : DIR
SCRIPT_DIR  = File.dirname(File.expand_path(__FILE__))
ANALYSE_RB  = File.join(SCRIPT_DIR, 'file_analyse.rb')

log_error("file_analyse.rb not found next to this script: #{ANALYSE_RB}") unless File.exist?(ANALYSE_RB)

require 'fileutils'
FileUtils.mkdir_p(CONFIG_DIR)

# =============================================================================
# MATCH FILES
# =============================================================================

source_files = Dir.glob(File.join(DIR, options[:pattern])).sort
log_error("No files matched #{options[:pattern]} in #{DIR}") if source_files.empty?

jobs    = []
skipped = []

source_files.each do |file|
  basename = File.basename(file, File.extname(file))
  config   = File.join(CONFIG_DIR, "#{basename}_config.yaml")
  if File.exist?(config) && !options[:overwrite]
    skipped << file
  else
    jobs << { file: file, config: config }
  end
end

log_section("Files to analyse")
log_ok("#{jobs.length} file(s) to analyse") if jobs.any?
jobs.each { |j| log_dim(File.basename(j[:file])) }

if skipped.any?
  log_warn("#{skipped.length} file(s) skipped — already have a config (use --overwrite to redo)")
  skipped.each { |f| log_dim(File.basename(f)) }
end

log_error("Nothing to do") if jobs.empty?

if options[:list_only]
  exit 0
end

if forward_args.any?
  log_section("Forwarding to every run")
  log_dim(forward_args.join(' '))
end

# =============================================================================
# RUN
# =============================================================================

results = []

jobs.each_with_index do |job, i|
  log_section("[#{i + 1}/#{jobs.length}] #{File.basename(job[:file])}")

  cmd = ['ruby', ANALYSE_RB, '--file', job[:file], '--output', job[:config]] + forward_args
  log_dim("$ #{cmd.join(' ')}")

  system(*cmd)
  success = $?.success?
  results << { file: job[:file], success: success }

  if success
    log_ok("Done: #{File.basename(job[:file])}")
  else
    log_warn("Failed: #{File.basename(job[:file])} (exit #{$?.exitstatus})")
    log_error("Stopping — --stop-on-error set") if options[:stop_on_error]
  end
end

# =============================================================================
# SUMMARY
# =============================================================================

log_section("Batch summary")
ok_count   = results.count { |r| r[:success] }
fail_count = results.length - ok_count

results.each do |r|
  r[:success] ? log_ok(File.basename(r[:file])) : log_warn("FAILED — #{File.basename(r[:file])}")
end

puts
puts "  #{c('Total:', C::DIM)}   #{results.length}"
puts "  #{c('Success:', C::DIM)} #{ok_count}"
puts "  #{c('Failed:', C::DIM)}  #{fail_count}"
puts

exit(fail_count.zero? ? 0 : 1)
