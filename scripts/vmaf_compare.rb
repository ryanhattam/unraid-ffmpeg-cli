#!/usr/bin/env ruby
# =============================================================================
# vmaf_compare.rb — Compare two video files using VMAF
# =============================================================================
# Usage:
#   ruby vmaf_compare.rb --reference original.mkv --encoded compressed.mkv
#   ruby vmaf_compare.rb -r original.mkv -e compressed.mkv --accurate
#   ruby vmaf_compare.rb -r original.mkv -e compressed.mkv --subsample 5
#
# All paths are resolved absolutely, so this script can be run from any
# directory regardless of where the input/output files live.
#
# The VMAF JSON log is written next to the encoded file (not CWD).
#
# Requirements:
#   ffmpeg (built with libvmaf)
#
# Example: 
#  ruby /Users/ryan/dev/personal/4k_encoder/vmaf_compare.rb -r '/Volumes/media/TV (Archive)/How I Met Your Mother (2005)/Season 01/How I Met Your Mother - S01E01 - Pilot - [WEBDL-1080p][AC3 5.1][h264].mkv' -e  '/Volumes/media/TV (Archive)/How I Met Your Mother (2005)/Season 01/How I Met Your Mother - S01E01 - Pilot - [WEBDL-1080p][AC3 5.1][h264]_h265.mkv' --subsample 5 --threads 8 --readrate 8
#
# =============================================================================

require 'optparse'
require 'open3'
require 'json'
require 'time'
require 'tmpdir'
require 'fileutils'

# =============================================================================
# COLOURS
# =============================================================================

module C
  RESET  = "\033[0m"
  BOLD   = "\033[1m"
  DIM    = "\033[2m"
  RED    = "\033[91m"
  GREEN  = "\033[92m"
  YELLOW = "\033[93m"
  CYAN   = "\033[96m"
  WHITE  = "\033[97m"
  BLUE   = "\033[94m"
end

def c(text, *codes) = "#{codes.join}#{text}#{C::RESET}"
def log_ok(msg)     = puts(c("  ✓  #{msg}", C::GREEN))
def log_warn(msg)   = puts(c("  ⚠  #{msg}", C::YELLOW))
def log_info(msg)   = puts(c("  ℹ  #{msg}", C::BLUE))
def log_dim(msg)    = puts(c("     #{msg}", C::DIM))
def log_error(msg)  = (puts(c("  ✗  #{msg}", C::RED)); exit 1)
def log_section(t)  = puts("\n#{c("── #{t}", C::CYAN, C::BOLD)}")

# =============================================================================
# HELPERS
# =============================================================================

def human_size(bytes)
  units = %w[B KB MB GB TB]
  exp   = [[Math.log(bytes) / Math.log(1024), 0].max.to_i, units.length - 1].min
  "%.2f %s" % [bytes.to_f / (1024**exp), units[exp]]
end

def run_cmd(cmd, log_file)
  log_dim("$ #{cmd.join(' ')}")
  File.open(log_file, 'a') { |f| f.puts "\n[#{Time.now}] #{cmd.join(' ')}\n" }

  Open3.popen2e(*cmd) do |_stdin, stdout_err, wait_thr|
    buf = +""
    loop do
      begin
        buf << stdout_err.read_nonblock(4096)
      rescue IO::WaitReadable
        IO.select([stdout_err])
        retry
      rescue EOFError
        break
      end
      while (idx = buf.index(/[\r\n]/))
        line = buf.slice!(0, idx + 1).chomp
        next if line.empty?
        File.open(log_file, 'a') { |f| f.puts line }
        if line =~ /frame=|time=|size=|speed=/
          $stderr.print "\r     #{line[0..120]}"
          $stderr.flush
        elsif line =~ /error|failed/i
          $stderr.puts ""
          log_warn(line)
        end
      end
    end
    $stderr.puts ""
    wait_thr.value.success?
  end
end

# =============================================================================
# OPTIONS
# =============================================================================

options = { subsample: 10, threads: 8, decode_threads: 4, readrate: 4 }

OptionParser.new do |opts|
  opts.banner = "Usage: ruby vmaf_compare.rb --reference REF --encoded ENC [options]"
  opts.on('-r PATH', '--reference PATH', 'Original/reference file (required)') { |v| options[:reference] = v }
  opts.on('-e PATH', '--encoded PATH',   'Encoded/compressed file (required)') { |v| options[:encoded]   = v }
  opts.on('--accurate',                  'Full-frame analysis (n_subsample=1, slower)') { options[:subsample] = 1 }
  opts.on('--subsample N', Integer,      "Check every Nth frame (default: #{options[:subsample]})") { |v| options[:subsample] = v }
  opts.on('--threads N',   Integer,      "libvmaf thread count (default: #{options[:threads]})")      { |v| options[:threads]   = v }
  opts.on('--decode-threads N', Integer, "Decoder threads per input (default: #{options[:decode_threads]})") { |v| options[:decode_threads] = v }
  opts.on('--readrate N', Float, "Cap input reads at N x realtime; bounds RAM (default: #{options[:readrate]}, 0 = uncapped)") { |v| options[:readrate] = v }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!

# Also accept bare positional args for convenience: vmaf_compare.rb ref enc [--accurate]
if options[:reference].nil? && ARGV.length >= 1
  options[:reference] = ARGV.shift
end
if options[:encoded].nil? && ARGV.length >= 1
  options[:encoded] = ARGV.shift
end

log_error("--reference is required") unless options[:reference]
log_error("--encoded is required")   unless options[:encoded]

# Resolve to absolute paths so the script works from any directory
ref_path = File.expand_path(options[:reference])
enc_path = File.expand_path(options[:encoded])

log_error("Reference file not found: #{ref_path}") unless File.exist?(ref_path)
log_error("Encoded file not found: #{enc_path}")   unless File.exist?(enc_path)

# Output files live next to the encoded file, not in CWD
enc_dir   = File.dirname(enc_path)
enc_base  = File.basename(enc_path, File.extname(enc_path))
timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
json_path = File.join(enc_dir, "#{enc_base}_vmaf.json")
log_path  = File.join(enc_dir, "#{enc_base}_vmaf_#{timestamp}.log")

# =============================================================================
# SUMMARY
# =============================================================================

ref_size  = File.size(ref_path)
enc_size  = File.size(enc_path)
reduction = ((1 - enc_size.to_f / ref_size) * 100).round(1)

puts
puts c('=' * 60, C::BOLD)
puts c('  vmaf_compare.rb — VMAF Quality Analysis', C::BOLD, C::WHITE)
puts c('=' * 60, C::BOLD)
puts
puts "  #{c('Reference:', C::DIM)}  #{ref_path}"
puts "  #{c('Size:', C::DIM)}       #{human_size(ref_size)}"
puts
puts "  #{c('Encoded:', C::DIM)}    #{enc_path}"
puts "  #{c('Size:', C::DIM)}       #{human_size(enc_size)} (#{reduction}% reduction)"
puts
puts "  #{c('Subsample:', C::DIM)}  every #{options[:subsample]} frame(s)#{options[:subsample] == 1 ? ' — accurate mode' : ''}"
puts "  #{c('Threads:', C::DIM)}    #{options[:threads]} libvmaf, #{options[:decode_threads]} per decoder"
puts "  #{c('Read rate:', C::DIM)}  #{options[:readrate].positive? ? "#{options[:readrate]}x realtime" : 'uncapped'}"
puts "  #{c('JSON log:', C::DIM)}   #{json_path}"
puts c('=' * 60, C::BOLD)

# =============================================================================
# RUN VMAF
# =============================================================================

log_section("Running VMAF analysis")
log_warn("Accurate mode active — this will be slow") if options[:subsample] == 1

# ffmpeg's filtergraph parser treats [ ] : , ; and spaces as syntax, so a
# log_path like ".../Movie (1998) [Remux][AVC].json" breaks parsing. Write
# the JSON to a safe temp path, then move it next to the encoded file.
tmp_json = File.join(Dir.tmpdir, "vmaf_#{Process.pid}_#{timestamp}.json")

# libvmaf expects: -i <distorted> -i <reference>
vmaf_filter = [
  "log_path=#{tmp_json}",
  "log_fmt=json",
  "n_threads=#{options[:threads]}",
  "n_subsample=#{options[:subsample]}"
].join(':')

# [N:V:0] pins each libvmaf pad to that input's first real video stream —
# capital V excludes attached pictures (cover art), which ffmpeg would
# otherwise auto-wire as the second input.
# setpts=PTS-STARTPTS zeroes both timelines so offset start times can't make
# the frame-sync queue buffer one input unboundedly (a major RAM sink).
# Decoder threads are capped per input: each decode thread holds a full raw
# frame in memory, and decoding outpaces VMAF scoring anyway.
filtergraph = "[0:V:0]setpts=PTS-STARTPTS[dis];" \
              "[1:V:0]setpts=PTS-STARTPTS[ref];" \
              "[dis][ref]libvmaf=#{vmaf_filter}"
# -an -sn -dn: without these ffmpeg auto-maps the "best" audio stream into
# the null output next to libvmaf's wrapped_avframe stream. The muxer then
# interleaves the two, buffering raw video frames (~3 MB each at 1080p)
# whenever the timelines drift — RAM balloons and throughput collapses.
#
# -readrate: the libvmaf filter accepts frames with no backpressure, so
# decoders running 10-20x realtime pile raw frame pairs (~6 MB each at
# 1080p) into libvmaf's queue faster than scoring drains it — multi-GB RAM
# on a full episode. Capping the read speed bounds the backlog.
input_opts = %W[-threads #{options[:decode_threads]}]
input_opts += %W[-readrate #{options[:readrate]}] if options[:readrate].positive?
cmd = %w[ffmpeg -y] +
      input_opts + %W[-i #{enc_path}] +
      input_opts + %W[-i #{ref_path}] +
      %W[-lavfi #{filtergraph} -an -sn -dn -f null -]

success = run_cmd(cmd, log_path)
FileUtils.mv(tmp_json, json_path) if File.exist?(tmp_json)
unless success
  # run_cmd only surfaces lines matching error/failed, but the root-cause
  # diagnostic often matches neither — show the tail of the full log.
  File.readlines(log_path).last(15).each { |l| log_dim(l.chomp) }
  log_error("VMAF analysis failed — check #{log_path}")
end

# =============================================================================
# PARSE RESULTS
# =============================================================================

log_error("VMAF JSON not found: #{json_path}") unless File.exist?(json_path)

begin
  vmaf_data = JSON.parse(File.read(json_path))
rescue JSON::ParserError => e
  log_error("Failed to parse VMAF JSON: #{e.message}")
end

vmaf_mean = vmaf_data.dig('pooled_metrics', 'vmaf', 'mean')
vmaf_min  = vmaf_data.dig('pooled_metrics', 'vmaf', 'min')
vmaf_max  = vmaf_data.dig('pooled_metrics', 'vmaf', 'max')
vmaf_hmean = vmaf_data.dig('pooled_metrics', 'vmaf', 'harmonic_mean')

# libvmaf includes harmonic_mean in pooled_metrics on recent builds; compute
# it from the per-frame scores if this build didn't.
if vmaf_hmean.nil?
  frame_scores = (vmaf_data['frames'] || []).filter_map { |f| f.dig('metrics', 'vmaf') }
  unless frame_scores.empty?
    vmaf_hmean = frame_scores.length / frame_scores.sum { |s| 1.0 / (s + 1) } - 1
  end
end

log_error("Could not find VMAF score in #{json_path}") unless vmaf_mean

quality, color = case vmaf_mean
  when 95..     then ['Excellent (Transparent)', C::GREEN]
  when 90...95  then ['Very Good',               C::GREEN]
  when 85...90  then ['Good',                    C::YELLOW]
  when 70...85  then ['Fair',                    C::YELLOW]
  else               ['Poor',                    C::RED]
end

# =============================================================================
# RESULTS
# =============================================================================

log_section("Results")
puts
puts "  #{c('VMAF (mean):', C::DIM)}  #{c(vmaf_mean.round(4).to_s, C::BOLD, C::WHITE)}"
puts "  #{c('VMAF (hmean):', C::DIM)} #{c(vmaf_hmean.round(4).to_s, C::BOLD, C::WHITE)}" if vmaf_hmean
puts "  #{c('VMAF (min):', C::DIM)}   #{vmaf_min&.round(4)}"
puts "  #{c('VMAF (max):', C::DIM)}   #{vmaf_max&.round(4)}"
puts
puts "  #{c('Quality:', C::DIM)}      #{c(quality, C::BOLD, color)}"
puts
puts c('=' * 60, C::BOLD)
puts "  #{c('Full log:', C::DIM)} #{json_path}"
puts c('=' * 60, C::BOLD)
puts
