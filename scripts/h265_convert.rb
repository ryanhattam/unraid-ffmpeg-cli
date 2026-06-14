#!/usr/bin/env ruby
# =============================================================================
# h265_convert.rb — Batch convert H264 video files to H265 (libx265)
# =============================================================================
# Scans a directory for MKV/MP4 files and re-encodes each one to H265.
# Skips files whose output already exists or whose name already ends with
# the output suffix (so re-running is always safe).
#
# Usage:
#   ruby h265_convert.rb                          # scan current directory
#   ruby h265_convert.rb --dir /path/to/season    # scan specific directory
#   ruby h265_convert.rb --dir /path/to/season --dry-run
#   ruby h265_convert.rb --dir . --crf 20 --preset medium
#
# Options:
#   --dir PATH         Directory to scan (default: current directory)
#   --crf N            CRF quality value (default: 17)
#   --preset PRESET    x265 preset (default: slow)
#   --suffix SUFFIX    Output filename suffix (default: _h265)
#   --no-recursive     Only scan top-level directory (default: recursive)
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

def run_encode(cmd, log_file)
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

options = { crf: 17, preset: 'slow', suffix: '_h265', recursive: true, dry_run: false }

OptionParser.new do |opts|
  opts.banner = "Usage: ruby h265_convert.rb [--dir PATH] [options]"
  opts.on('--dir PATH',        'Directory to scan (default: current directory)') { |v| options[:dir]     = v }
  opts.on('--crf N',   Integer, 'CRF quality value (default: 17)')               { |v| options[:crf]     = v }
  opts.on('--preset P',        'x265 preset (default: slow)')                    { |v| options[:preset]  = v }
  opts.on('--suffix S',        'Output filename suffix (default: _h265)')        { |v| options[:suffix]  = v }
  opts.on('--no-recursive',    'Only scan top-level directory')                  { options[:recursive]   = false }
  opts.on('--dry-run',         'Show what would be encoded, do not encode')      { options[:dry_run]     = true }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!

scan_dir = File.expand_path(options[:dir] || Dir.pwd)
log_error("Directory not found: #{scan_dir}") unless Dir.exist?(scan_dir)

suffix  = options[:suffix]
crf     = options[:crf]
preset  = options[:preset]
dry_run = options[:dry_run]

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
    status = File.exist?(output) ? c("SKIP (exists)", C::DIM) : c("ENCODE", C::CYAN)
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

  timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
  log_file  = File.join(dir, "#{base}_h265_#{timestamp}.log")

  log_step(idx + 1, total, File.basename(input))

  if File.exist?(output)
    log_skip("Output already exists: #{File.basename(output)}")
    skipped += 1
    next
  end

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
    log_warn("Failed — check #{log_file}")
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
