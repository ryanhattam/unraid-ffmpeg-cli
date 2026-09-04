#!/usr/bin/env ruby
# =============================================================================
# file_batch_encode.rb — Run file_encode.rb against every file in a directory
#                         that has a matching config
# =============================================================================
# Scans a directory for source video files that have a matching
# "<basename>_config.yaml" (as produced by file_analyse.rb), and runs
# file_encode.rb once per pair, forwarding any extra arguments to every
# invocation. Each run's own duplicate-output check (confirm prompt in
# file_encode.rb) is preserved as-is — this script does not skip or
# force-overwrite existing outputs itself.
#
# Usage:
#   ruby file_batch_encode.rb --dir /media/movies
#   ruby file_batch_encode.rb --dir /media/movies -- --dry-run
#   ruby file_batch_encode.rb --dir /media/movies -- --crf 18 --keep-dv-profile
#   ruby file_batch_encode.rb --dir /media/movies --output-dir /media/out -- --keep-temp
#
# Everything after `--` is forwarded verbatim to file_encode.rb for every
# file (e.g. --crf, --keep-dv-profile, --output-dir, --dry-run, --keep-temp).
#
# Options:
#   --dir PATH          Directory containing source video files (required)
#   --config-dir PATH   Directory containing *_config.yaml files (default: --dir)
#   --pattern GLOB       Glob (relative to --dir) for source files (default: *.mkv)
#   --stop-on-error      Abort the batch on the first failed file (default: continue)
#   --list-only          List matched file/config pairs and exit, run nothing
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

options = { dir: nil, config_dir: nil, pattern: '*.mkv', stop_on_error: false, list_only: false }

# Split ARGV on `--`: everything before is ours, everything after is forwarded.
sep_index = ARGV.index('--')
own_args, forward_args = if sep_index
  [ARGV[0...sep_index], ARGV[(sep_index + 1)..]]
else
  [ARGV, []]
end

OptionParser.new do |opts|
  opts.banner = "Usage: ruby file_batch_encode.rb --dir DIR [options] [-- ENCODE_ARGS...]"
  opts.on('--dir PATH',        'Directory of source video files (required)') { |v| options[:dir] = v }
  opts.on('--config-dir PATH', 'Directory of *_config.yaml files (default: --dir)') { |v| options[:config_dir] = v }
  opts.on('--pattern GLOB',    'Glob for source files (default: *.mkv)')     { |v| options[:pattern] = v }
  opts.on('--stop-on-error',   'Abort on first failed file')                { options[:stop_on_error] = true }
  opts.on('--list-only',       'List matched pairs and exit')               { options[:list_only] = true }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!(own_args)

log_error("--dir is required") unless options[:dir]
log_error("Directory not found: #{options[:dir]}") unless Dir.exist?(options[:dir])

DIR        = File.expand_path(options[:dir])
CONFIG_DIR = options[:config_dir] ? File.expand_path(options[:config_dir]) : DIR
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))
ENCODE_RB  = File.join(SCRIPT_DIR, 'file_encode.rb')

log_error("file_encode.rb not found next to this script: #{ENCODE_RB}") unless File.exist?(ENCODE_RB)
log_error("Config directory not found: #{CONFIG_DIR}") unless Dir.exist?(CONFIG_DIR)

# =============================================================================
# MATCH FILES TO CONFIGS
# =============================================================================

source_files = Dir.glob(File.join(DIR, options[:pattern])).sort
log_error("No files matched #{options[:pattern]} in #{DIR}") if source_files.empty?

jobs    = []
skipped = []

source_files.each do |file|
  basename = File.basename(file, File.extname(file))
  config   = File.join(CONFIG_DIR, "#{basename}_config.yaml")
  if File.exist?(config)
    jobs << { file: file, config: config }
  else
    skipped << file
  end
end

log_section("Matched files")
log_ok("#{jobs.length} file(s) with a config found") if jobs.any?
jobs.each { |j| log_dim(File.basename(j[:file])) }

if skipped.any?
  log_warn("#{skipped.length} file(s) skipped — no matching config")
  skipped.each { |f| log_dim(File.basename(f)) }
end

log_error("No files have a matching config — nothing to do") if jobs.empty?

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

  cmd = ['ruby', ENCODE_RB, '--file', job[:file], '--config', job[:config]] + forward_args
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
