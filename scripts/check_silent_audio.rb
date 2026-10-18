#!/usr/bin/env ruby
# =============================================================================
# check_silent_audio.rb — Diagnose silent/near-silent audio in encoded output
# =============================================================================
# Runs ffmpeg's volumedetect filter over the first audio stream of each
# matched file and flags anything suspiciously quiet. Meant to help track
# down which specific files/codecs are affected by silent-audio output from
# file_encode.rb, not to fix anything itself.
#
# Usage:
#   ruby check_silent_audio.rb --file "Movie_x265_crf18.mkv"
#   ruby check_silent_audio.rb --dir /media/movies --pattern "*_x265_*.mkv"
#
# Options:
#   --file PATH    Single file to check
#   --dir PATH     Directory to scan
#   --pattern GLOB Glob relative to --dir (default: *.mkv)
#   --threshold DB Flag files with max_volume below this, in dB (default: -40)
# =============================================================================

require 'optparse'
require 'open3'

module C
  RESET = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"
  RED = "\033[91m"; GREEN = "\033[92m"; YELLOW = "\033[93m"; CYAN = "\033[96m"; WHITE = "\033[97m"
end

def c(text, *codes) = "#{codes.join}#{text}#{C::RESET}"
def log_ok(msg)     = puts(c("  ✓  #{msg}", C::GREEN))
def log_warn(msg)   = puts(c("  ⚠  #{msg}", C::YELLOW))
def log_dim(msg)    = puts(c("     #{msg}", C::DIM))
def log_error(msg)  = (puts(c("  ✗  #{msg}", C::RED)); exit 1)
def log_section(t)  = puts("\n#{c("── #{t}", C::CYAN, C::BOLD)}")

options = { pattern: '*.mkv', threshold: -40.0 }

OptionParser.new do |opts|
  opts.banner = "Usage: ruby check_silent_audio.rb --file PATH | --dir PATH [options]"
  opts.on('--file PATH',    'Single file to check')            { |v| options[:file] = v }
  opts.on('--dir PATH',     'Directory to scan')                { |v| options[:dir] = v }
  opts.on('--pattern GLOB', 'Glob for files (default: *.mkv)')  { |v| options[:pattern] = v }
  opts.on('--threshold DB', Float, 'Flag below this max_volume dB (default: -40)') { |v| options[:threshold] = v }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!

log_error("Provide --file or --dir") unless options[:file] || options[:dir]

files = if options[:file]
  log_error("File not found: #{options[:file]}") unless File.exist?(options[:file])
  [options[:file]]
else
  log_error("Directory not found: #{options[:dir]}") unless Dir.exist?(options[:dir])
  Dir.glob(File.join(File.expand_path(options[:dir]), options[:pattern])).sort
end

log_error("No files matched") if files.empty?

def probe_volume(file)
  cmd = %W[ffmpeg -nostdin -i #{file} -map 0:a:0 -af volumedetect -f null -]
  _stdout, stderr, status = Open3.capture3(*cmd)
  return { ok: false, error: 'ffmpeg failed' } unless status.success? || stderr.include?('mean_volume')

  mean = stderr[/mean_volume:\s*(-?\d+(\.\d+)?)/, 1]
  max  = stderr[/max_volume:\s*(-?\d+(\.\d+)?)/, 1]

  return { ok: false, error: 'no audio stream / could not measure' } unless mean && max

  { ok: true, mean: mean.to_f, max: max.to_f }
end

log_section("Checking #{files.length} file(s)")

results = files.map do |file|
  log_dim("Analysing #{File.basename(file)}...")
  metrics = probe_volume(file)
  { file: file }.merge(metrics)
end

log_section("Results")

results.each do |r|
  name = File.basename(r[:file])
  if !r[:ok]
    log_warn("#{name} — #{r[:error]}")
  elsif r[:max] <= options[:threshold]
    log_warn("#{name} — SUSPECT SILENT (mean #{r[:mean]} dB, max #{r[:max]} dB)")
  else
    log_ok("#{name} — mean #{r[:mean]} dB, max #{r[:max]} dB")
  end
end

suspects = results.select { |r| r[:ok] && r[:max] <= options[:threshold] }
puts
if suspects.any?
  log_warn("#{suspects.length} file(s) below #{options[:threshold]} dB threshold — likely silent/near-silent audio")
else
  log_ok("No suspiciously silent files found")
end
puts
