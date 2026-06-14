#!/usr/bin/env ruby
# =============================================================================
# test_encode.rb — Test encode + VMAF quality preview before full encode
# =============================================================================
# Extracts a short clip, runs a full encode pipeline on it using the same
# settings as file_encode.rb, then measures quality with vmaf_compare.rb —
# so you can validate CRF/preset before committing to hours of encoding.
#
# Usage:
#   test_encode.rb --file movie.mkv
#   test_encode.rb --file movie.mkv --crf 18 --preset medium
#   test_encode.rb --file movie.mkv --duration 90 --start 1200
#
# Options:
#   --file PATH       Source MKV file (required)
#   --crf N           Starting CRF value (default: 17)
#   --preset NAME     x265 preset (default: fast)
#   --duration N      Clip length in seconds (default: 60)
#   --start N         Clip start time in seconds (default: 25% into file)
#   --dry-run         Show commands without running them
#   --keep-temp       Keep intermediate files after finishing
# =============================================================================

require 'optparse'
require 'open3'
require 'fileutils'
require 'time'
require 'json'
require 'yaml'

SCRIPTS_DIR    = File.dirname(File.expand_path(__FILE__))
ANALYSE_SCRIPT = File.join(SCRIPTS_DIR, 'file_analyse.rb')
ENCODE_SCRIPT  = File.join(SCRIPTS_DIR, 'file_encode.rb')
VMAF_SCRIPT    = File.join(SCRIPTS_DIR, 'vmaf_compare.rb')

# =============================================================================
# COLOURS + LOGGING
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

def confirm(prompt)
  print "\n#{c("  ? ", C::YELLOW, C::BOLD)}#{c(prompt, C::WHITE)} #{c("[y/N] ", C::DIM)}"
  r = $stdin.gets&.chomp&.downcase || 'n'
  r == 'y' || r == 'yes'
end

def ask(prompt, default: nil)
  hint = default ? " #{c("[#{default}]", C::DIM)}" : ''
  print "\n#{c("  ? ", C::YELLOW, C::BOLD)}#{c(prompt, C::WHITE)}#{hint} "
  input = $stdin.gets&.chomp
  (input.nil? || input.empty?) ? default : input
end

# =============================================================================
# OPTIONS
# =============================================================================

DEFAULT_CRF      = 17
DEFAULT_PRESET   = 'fast'
DEFAULT_DURATION = 120

options = {
  crf:       DEFAULT_CRF,
  preset:    DEFAULT_PRESET,
  duration:  DEFAULT_DURATION,
  dry_run:   false,
  keep_temp: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: test_encode.rb --file INPUT.mkv [options]"
  opts.on('--file PATH',           'Source MKV file (required)')                       { |v| options[:file]      = v }
  opts.on('--crf N',     Integer,  "Starting CRF (default: #{DEFAULT_CRF})")           { |v| options[:crf]       = v }
  opts.on('--preset NAME',         "x265 preset (default: #{DEFAULT_PRESET})")         { |v| options[:preset]    = v }
  opts.on('--duration N', Integer, "Clip length in seconds (default: #{DEFAULT_DURATION})") { |v| options[:duration] = v }
  opts.on('--start N',   Integer,  'Clip start time in seconds (default: auto)')       { |v| options[:start]     = v }
  opts.on('--dry-run',             'Show commands, do not encode')                     { options[:dry_run]       = true }
  opts.on('--keep-temp',           'Keep intermediate files')                          { options[:keep_temp]     = true }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!

log_error("--file is required")                unless options[:file]
log_error("File not found: #{options[:file]}") unless File.exist?(options[:file])
log_error("--crf must be between 0 and 51")    unless (0..51).include?(options[:crf])

input     = File.expand_path(options[:file])
basename  = File.basename(input, File.extname(input))
input_dir = File.dirname(input)
timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
temp_dir  = File.join(input_dir, ".test_encode_#{timestamp}")

FileUtils.mkdir_p(temp_dir) unless options[:dry_run]

clip_path   = File.join(temp_dir, "#{basename}_clip.mkv")
config_path = File.join(temp_dir, "#{basename}_clip_config.yaml")

# =============================================================================
# HEADER
# =============================================================================

puts
puts c('=' * 60, C::BOLD)
puts c('  test_encode.rb — Test Encode + VMAF Preview', C::BOLD, C::WHITE)
puts c('  Extract → Analyse → Encode → VMAF → Decide', C::DIM)
puts c('=' * 60, C::BOLD)
puts
puts "  #{c('Source:', C::DIM)}    #{File.basename(input)}"
puts "  #{c('CRF:', C::DIM)}       #{options[:crf]}"
puts "  #{c('Preset:', C::DIM)}    #{options[:preset]}"
puts "  #{c('Clip:', C::DIM)}      #{options[:duration]}s"
puts "  #{c('Temp dir:', C::DIM)}  #{temp_dir}"

# =============================================================================
# STEP 1: PROBE + EXTRACT CLIP
# =============================================================================

log_section("[1/4] Extracting clip")

duration_s = begin
  out, _err, st = Open3.capture3(
    'ffprobe', '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'json', input
  )
  st.success? ? JSON.parse(out).dig('format', 'duration')&.to_f : nil
rescue
  nil
end

if duration_s
  log_ok("Duration: #{(duration_s / 60).to_i}m #{(duration_s % 60).to_i}s")
else
  log_warn("Could not determine file duration — using start time 0")
end

start_s = options[:start] || begin
  if duration_s && duration_s > options[:duration]
    candidate = (duration_s * 0.25).to_i
    max_start = (duration_s - options[:duration]).to_i
    [candidate, max_start].min
  else
    0
  end
end

log_info("Clip: #{options[:duration]}s starting at #{start_s}s (#{start_s / 60}m#{start_s % 60}s)")

extract_cmd = %W[ffmpeg -y -ss #{start_s} -i #{input} -t #{options[:duration]} -c copy #{clip_path}]

if options[:dry_run]
  log_dim("$ #{extract_cmd.join(' ')}")
else
  log_dim("$ #{extract_cmd.join(' ')}")
  success = system(*extract_cmd)
  log_error("Clip extraction failed") unless success
  log_ok("Clip extracted: #{File.basename(clip_path)}")
end

# =============================================================================
# STEP 2: ANALYSE CLIP
# =============================================================================

log_section("[2/4] Analysing clip")

analyse_cmd = %W[
  ruby #{ANALYSE_SCRIPT}
  --file #{clip_path}
  --crf #{options[:crf]}
  --preset #{options[:preset]}
  --output #{config_path}
]

if options[:dry_run]
  log_dim("$ #{analyse_cmd.join(' ')}")
else
  success = system(*analyse_cmd)
  log_error("Analysis failed") unless success
end

cfg = {}
if File.exist?(config_path)
  cfg = YAML.safe_load(File.read(config_path), permitted_classes: [Symbol])
             &.transform_keys(&:to_s) || {}
  puts
  puts "  #{c('Resolution:', C::DIM)}  #{cfg['resolution']}"
  puts "  #{c('HDR:', C::DIM)}         #{cfg['hdr']}"
  puts "  #{c('Audio:', C::DIM)}       #{cfg['audio_description']}"
  puts "  #{c('Dolby Vision:', C::DIM)} #{cfg['has_dv'] ? 'yes' : 'no'}"
  if cfg['warnings'] && !cfg['warnings'].empty?
    cfg['warnings'].each { |w| log_warn(w) }
  end
end

unless options[:dry_run]
  log_error("Could not load config after analysis") if cfg.empty?
end

# =============================================================================
# ENCODE + VMAF LOOP
# =============================================================================

current_crf = options[:crf]

loop do
  # ── Step 3: Encode clip ────────────────────────────────────────────────────

  log_section("[3/4] Encoding clip (CRF #{current_crf}, #{options[:preset]})")

  encoded_path = File.join(temp_dir, "#{basename}_clip_crf#{current_crf}.mkv")

  if options[:dry_run]
    log_dim("$ ruby #{ENCODE_SCRIPT} --file #{clip_path} --config #{config_path} --crf #{current_crf} --output-dir #{temp_dir} --output-name #{File.basename(encoded_path)} --yes")
  elsif File.exist?(encoded_path)
    log_info("Reusing cached encode for CRF #{current_crf}: #{File.basename(encoded_path)}")
  else
    encode_cmd = %W[
      ruby #{ENCODE_SCRIPT}
      --file #{clip_path}
      --config #{config_path}
      --crf #{current_crf}
      --output-dir #{temp_dir}
      --output-name #{File.basename(encoded_path)}
      --yes
    ]
    success = system(*encode_cmd)
    log_error("Clip encode failed") unless success
    log_ok("Clip encoded: #{File.basename(encoded_path)}")
  end

  # ── Step 4: VMAF ───────────────────────────────────────────────────────────

  log_section("[4/4] VMAF analysis")

  if options[:dry_run]
    log_dim("$ ruby #{VMAF_SCRIPT} --reference #{clip_path} --encoded #{encoded_path}")
  else
    vmaf_cmd = %W[ruby #{VMAF_SCRIPT} --reference #{clip_path} --encoded #{encoded_path}]
    success  = system(*vmaf_cmd)
    log_warn("VMAF analysis did not complete cleanly") unless success
  end

  # ── Decision menu ──────────────────────────────────────────────────────────

  puts
  puts c('─' * 60, C::DIM)
  puts c("  What next?", C::BOLD, C::WHITE)
  puts
  puts "  #{c('1', C::BOLD, C::GREEN)}  Proceed with full encode (CRF #{current_crf}, #{options[:preset]})"
  puts "  #{c('2', C::BOLD, C::YELLOW)}  Try a different CRF"
  puts "  #{c('3', C::BOLD, C::RED)}  Quit without encoding"
  puts c('─' * 60, C::DIM)
  print "\n  #{c('Choice [1/2/3]:', C::DIM)} "

  choice = $stdin.gets&.chomp

  case choice
  when '1'
    log_section("Full encode")
    full_encode_cmd = %W[
      ruby #{ENCODE_SCRIPT}
      --file #{input}
      --config #{config_path}
      --crf #{current_crf}
      --yes
    ]
    if options[:dry_run]
      log_dim("$ #{full_encode_cmd.join(' ')}")
    else
      log_info("Starting full encode — this will take a while")
      success = system(*full_encode_cmd)
      log_error("Full encode failed") unless success
      log_ok("Full encode complete!")
    end
    break

  when '2'
    new_crf = ask("Enter CRF (0–51, lower = better quality, higher = smaller file):", default: current_crf.to_s)
    n = new_crf.to_i
    if (0..51).include?(n)
      current_crf = n
    else
      log_warn("Invalid CRF '#{new_crf}' — keeping #{current_crf}")
    end
    next

  when '3', nil
    log_info("Exiting — no full encode started.")
    break

  else
    log_warn("Unknown choice — enter 1, 2, or 3")
  end
end

# =============================================================================
# CLEANUP
# =============================================================================

unless options[:keep_temp] || options[:dry_run]
  log_section("Cleaning up")
  FileUtils.rm_rf(temp_dir)
  log_ok("Temp files removed")
end

puts
puts c('=' * 60, C::BOLD)
puts c('  Done', C::BOLD, C::GREEN)
puts c('=' * 60, C::BOLD)
puts
