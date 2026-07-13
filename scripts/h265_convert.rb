#!/usr/bin/env ruby
# =============================================================================
# h265_convert.rb — Batch convert H264 video files to H265 (libx265)
# =============================================================================
# Scans a directory for MKV/MP4 files and re-encodes each one to H265.
# Skips files whose output already exists or whose name already ends with
# the output suffix (so re-running is always safe).
#
# Usage:
#   ruby h265_convert.rb --dir /path/to/season    # scan specific directory
#   ruby h265_convert.rb --dir /path/to/season --dry-run
#   ruby h265_convert.rb --dir . --crf 20 --preset medium
#
# Options:
#   --dir PATH         Directory to scan (required)
#   --crf N            CRF quality value (default: 18)
#   --preset PRESET    x265 preset (default: slow)
#   --suffix SUFFIX    Output filename suffix (default: _h265)
#   --min-bpp N        Skip files below this bits-per-pixel (default: 0.05).
#                      Low-bpp sources are already efficiently compressed and
#                      are unlikely to shrink 10%+ when re-encoded to H265.
#   --no-bpp-check     Encode every file regardless of bits-per-pixel
#   --no-recursive     Only scan top-level directory (default: recursive)
#   --log              Write ffmpeg output to a per-file log (default: off)
#   --dry-run          Show what would be encoded, do not encode
#   --keep-original    Keep the original file after encoding (default: kept)
#
# Requirements:
#   ffmpeg (with libx265)
# =============================================================================

require 'optparse'
require 'open3'
require 'fileutils'
require 'time'
require 'json'

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
def log_skip(msg)   = puts(c("  ⤼  #{msg}", C::DIM))

def log_step(n, total, msg)
  puts "\n#{c("[#{n}/#{total}]", C::BOLD, C::WHITE)} #{c(msg, C::CYAN, C::BOLD)}"
end

# =============================================================================
# HELPERS
# =============================================================================

def human_size(bytes)
  units = %w[B KB MB GB TB]
  exp   = [[Math.log([bytes, 1].max) / Math.log(1024), 0].max.to_i, units.length - 1].min
  "%.2f %s" % [bytes.to_f / (1024**exp), units[exp]]
end

def elapsed_str(seconds)
  h = (seconds / 3600).to_i
  m = ((seconds % 3600) / 60).to_i
  s = (seconds % 60).to_i
  h > 0 ? "#{h}h #{m}m #{s}s" : m > 0 ? "#{m}m #{s}s" : "#{s}s"
end

# Bits-per-pixel of the first video stream: bitrate / (width * height * fps).
# Uses the container bitrate (or size/duration as a fallback), so audio is
# included — good enough for a rough "is re-encoding worth it" triage.
# Returns nil if the file can't be probed.
def probe_bpp(path)
  out, _err, status = Open3.capture3(
    'ffprobe', '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height,avg_frame_rate',
    '-show_entries', 'format=duration,bit_rate',
    '-of', 'json', path
  )
  return nil unless status.success?

  data   = JSON.parse(out)
  stream = data['streams']&.first or return nil
  width  = stream['width'].to_i
  height = stream['height'].to_i
  num, den = stream['avg_frame_rate'].to_s.split('/').map(&:to_f)
  fps = den && den > 0 ? num / den : 0.0
  return nil if width <= 0 || height <= 0 || fps <= 0

  bitrate = data.dig('format', 'bit_rate').to_f
  if bitrate <= 0
    duration = data.dig('format', 'duration').to_f
    bitrate  = duration > 0 ? File.size(path) * 8 / duration : 0.0
  end
  return nil if bitrate <= 0

  bitrate / (width * height * fps)
rescue JSON::ParserError, Errno::ENOENT
  nil
end

def run_encode(cmd, log_file)
  File.open(log_file, 'a') { |f| f.puts "\n[#{Time.now}] #{cmd.join(' ')}\n" } if log_file

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
        File.open(log_file, 'a') { |f| f.puts line } if log_file
        if line =~ /frame=|time=|size=|speed=/
          $stderr.print "\r     #{line[0..120]}"
          $stderr.flush
        elsif line =~ /x265 \[error\]|Error(?!.*skipping)|failed/i
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

options = { crf: 18, preset: 'medium', suffix: '_h265', recursive: true, dry_run: false, min_bpp: 0.05 }

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby h265_convert.rb --dir PATH [options]"
  opts.on('--dir PATH',        'Directory to scan (required)')                   { |v| options[:dir]     = v }
  opts.on('--crf N',   Integer, 'CRF quality value (default: 17)')               { |v| options[:crf]     = v }
  opts.on('--preset P',        'x265 preset (default: medium)')                    { |v| options[:preset]  = v }
  opts.on('--suffix S',        'Output filename suffix (default: _h265)')        { |v| options[:suffix]  = v }
  opts.on('--min-bpp N', Float, 'Skip files below this bits-per-pixel (default: 0.05)') { |v| options[:min_bpp] = v }
  opts.on('--no-bpp-check',    'Encode regardless of bits-per-pixel')            { options[:min_bpp]     = nil }
  opts.on('--no-recursive',    'Only scan top-level directory')                  { options[:recursive]   = false }
  opts.on('--log',             'Write ffmpeg output to a per-file log')          { options[:log]         = true }
  opts.on('--dry-run',         'Show what would be encoded, do not encode')      { options[:dry_run]     = true }
  opts.on('--help', 'Show help') { puts opts; exit }
end
parser.parse!

if options[:dir].nil?
  puts parser
  exit 1
end

scan_dir = File.expand_path(options[:dir])
log_error("Directory not found: #{scan_dir}") unless Dir.exist?(scan_dir)

suffix  = options[:suffix]
crf     = options[:crf]
preset  = options[:preset]
dry_run = options[:dry_run]
min_bpp = options[:min_bpp]

# =============================================================================
# DISCOVER FILES
# =============================================================================

glob_depth = options[:recursive] ? '**/' : ''
candidates = Dir.glob(File.join(scan_dir, "#{glob_depth}*.{mkv,mp4,MKV,MP4}")).sort

# Exclude files whose basename already ends with the suffix — these are outputs
# from a previous run, so re-encoding them would be double-encoding.
input_files = candidates.reject do |f|
  File.basename(f, File.extname(f)).end_with?(suffix)
end

# =============================================================================
# HEADER
# =============================================================================

puts
puts c('=' * 60, C::BOLD)
puts c('  h265_convert.rb — Batch H264 → H265', C::BOLD, C::WHITE)
puts c('=' * 60, C::BOLD)
puts "  #{c('Directory:', C::DIM)}  #{scan_dir}"
puts "  #{c('Files found:', C::DIM)} #{input_files.length}"
puts "  #{c('CRF:', C::DIM)}        #{crf}"
puts "  #{c('Preset:', C::DIM)}     #{preset}"
puts "  #{c('Recursive:', C::DIM)}  #{options[:recursive]}"
puts "  #{c('Min bpp:', C::DIM)}    #{min_bpp ? format('%.3f', min_bpp) : 'disabled'}"
puts c('=' * 60, C::BOLD)

if input_files.empty?
  log_info("No MKV/MP4 files found in #{scan_dir}")
  exit 0
end

log_section("Files to process")
input_files.each { |f| log_dim(f.sub(scan_dir + '/', '')) }

if dry_run
  puts
  log_info("Dry run — no files will be encoded")
  input_files.each do |input|
    dir    = File.dirname(input)
    base   = File.basename(input, File.extname(input))
    output = File.join(dir, "#{base}#{suffix}.mkv")
    status =
      if File.exist?(output)
        c("SKIP (exists)", C::DIM)
      elsif min_bpp && (bpp = probe_bpp(input)) && bpp < min_bpp
        c(format("SKIP (bpp %.3f < %.3f)", bpp, min_bpp), C::DIM)
      elsif min_bpp && bpp
        c(format("ENCODE (bpp %.3f)", bpp), C::CYAN)
      else
        c("ENCODE", C::CYAN)
      end
    puts "  #{status}  #{input.sub(scan_dir + '/', '')}"
  end
  puts
  exit 0
end

# =============================================================================
# ENCODE LOOP
# =============================================================================

total     = input_files.length
done      = 0
skipped   = 0
failed    = 0
wall_start = Time.now

input_files.each_with_index do |input, idx|
  dir    = File.dirname(input)
  base   = File.basename(input, File.extname(input))
  output = File.join(dir, "#{base}#{suffix}.mkv")

  log_file =
    if options[:log]
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      File.join(dir, "#{base}_h265_#{timestamp}.log")
    end

  log_step(idx + 1, total, File.basename(input))

  if File.exist?(output)
    log_skip("Output already exists: #{File.basename(output)}")
    skipped += 1
    next
  end

  if min_bpp
    bpp = probe_bpp(input)
    if bpp.nil?
      log_warn("Could not determine bits-per-pixel — encoding anyway")
    elsif bpp < min_bpp
      log_skip(format("Bits-per-pixel %.3f is below %.3f — unlikely to shrink 10%%+, skipping", bpp, min_bpp))
      skipped += 1
      next
    else
      log_dim(format("Bits-per-pixel: %.3f (threshold %.3f)", bpp, min_bpp))
    end
  end

  log_dim("Input:  #{input}")
  log_dim("Output: #{output}")

  cmd = %W[
    ffmpeg -y
    -i #{input}
    -c:v libx265
    -crf #{crf}
    -preset #{preset}
    -c:a copy
    -c:s copy
    -map 0
    -tag:v hvc1
    #{output}
  ]

  file_start = Time.now
  success    = run_encode(cmd, log_file)

  if success
    input_size  = File.size(input)
    output_size = File.size(output)
    reduction   = ((1 - output_size.to_f / input_size) * 100).round(1)
    log_ok("Done in #{elapsed_str(Time.now - file_start)} — #{human_size(input_size)} → #{human_size(output_size)} (#{reduction}% reduction)")
    done += 1
  else
    log_warn(log_file ? "Failed — check #{log_file}" : "Failed — re-run with --log to capture ffmpeg output")
    # Remove partial output if it exists
    FileUtils.rm_f(output)
    failed += 1
  end
end

# =============================================================================
# SUMMARY
# =============================================================================

elapsed = Time.now - wall_start

puts
puts c('=' * 60, C::BOLD)
puts c('  Done!', C::BOLD, C::GREEN)
puts c('=' * 60, C::BOLD)
puts "  #{c('Encoded:', C::DIM)}  #{done}"
puts "  #{c('Skipped:', C::DIM)}  #{skipped}"
puts "  #{c('Failed:', C::DIM)}   #{failed}"
puts "  #{c('Total time:', C::DIM)} #{elapsed_str(elapsed)}"
puts c('=' * 60, C::BOLD)
puts

exit(failed > 0 ? 1 : 0)
