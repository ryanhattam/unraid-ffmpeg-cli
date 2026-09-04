#!/usr/bin/env ruby
# =============================================================================
# analyse_local.rb — Analyse media file and generate YAML config locally
# =============================================================================
# Runs ffprobe and mediainfo on a source MKV, then generates a YAML config
# directly without needing to call Claude.
#
# Usage:
#   ruby analyse_local.rb --file "Movie.mkv"
#   ruby analyse_local.rb --file "Movie.mkv" --crf 16 --preset medium
#   ruby analyse_local.rb --file "Movie.mkv" --output config.yaml
#
# Options:
#   --file PATH          Source MKV file (required)
#   --crf N              CRF value (default: 17)
#   --preset NAME        x265 preset: ultrafast, fast, medium, slow (default: fast)
#   --output PATH        Save config to file (default: <basename>_config.yaml)
# =============================================================================

require 'optparse'
require 'open3'
require 'yaml'
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
end

def c(text, *codes) = "#{codes.join}#{text}#{C::RESET}"
def log_ok(msg)     = puts(c("  ✓  #{msg}", C::GREEN))
def log_warn(msg)   = puts(c("  ⚠  #{msg}", C::YELLOW))
def log_dim(msg)    = puts(c("     #{msg}", C::DIM))
def log_error(msg)  = (puts(c("  ✗  #{msg}", C::RED)); exit 1)
def log_section(t)  = puts("\n#{c("── #{t}", C::CYAN, C::BOLD)}")

# =============================================================================
# OPTIONS
# =============================================================================

options = { crf: 15, preset: 'medium' }

OptionParser.new do |opts|
  opts.banner = "Usage: ruby analyse_local.rb --file INPUT.mkv [options]"
  opts.on('--file PATH',    'Source MKV file (required)')          { |v| options[:file]    = v }
  opts.on('--crf N',        'CRF value (default: 17)')             { |v| options[:crf]     = v.to_i }
  opts.on('--preset NAME',  'x265 preset (default: fast)')         { |v| options[:preset]  = v }
  opts.on('--output PATH',  'Save config to file')                 { |v| options[:output]  = v }
  opts.on('--help', 'Show help') { puts opts; exit }
end.parse!

log_error("--file is required") unless options[:file]
log_error("File not found: #{options[:file]}") unless File.exist?(options[:file])

input    = File.expand_path(options[:file])
basename = File.basename(input, File.extname(input))

# =============================================================================
# HELPERS
# =============================================================================

def command_exists?(cmd)
  system("which #{cmd} > /dev/null 2>&1")
end

# =============================================================================
# FFPROBE PARSING
# =============================================================================

def parse_ffprobe(filepath)
  log_dim("Running ffprobe...")
  cmd = %W[
    ffprobe -analyzeduration 100M -probesize 100M
    -v error
    -show_entries stream=index,codec_name,codec_type,channels,bit_rate,channel_layout,sample_rate
    -show_entries stream_tags=language,title
    -of json
    #{filepath}
  ]
  stdout, stderr, status = Open3.capture3(*cmd)
  log_error("ffprobe failed: #{stderr}") unless status.success?
  
  data = JSON.parse(stdout)
  streams = data['streams'] || []
  
  # Normalize stream data
  streams.map do |s|
    {
      'index' => s['index'],
      'codec_name' => s['codec_name'],
      'codec_type' => s['codec_type'],
      'channels' => s['channels']&.to_i,
      'bit_rate' => s['bit_rate'],
      'channel_layout' => s['channel_layout'],
      'sample_rate' => s['sample_rate'],
      'language' => s.dig('tags', 'language'),
      'title' => s.dig('tags', 'title')
    }
  end
end

# =============================================================================
# MEDIAINFO PARSING
# =============================================================================

def parse_mediainfo(filepath)
  log_dim("Running mediainfo...")
  stdout, stderr, status = Open3.capture3('mediainfo', '--Output=JSON', filepath)
  log_error("mediainfo failed: #{stderr}") unless status.success?
  
  data = JSON.parse(stdout)
  tracks = data.dig('media', 'track') || []
  
  # Extract relevant info
  general = tracks.find { |t| t['@type'] == 'General' } || {}
  video = tracks.find { |t| t['@type'] == 'Video' } || {}
  
  {
    file_size: general['FileSize_String'] || format_bytes(general['FileSize']&.to_i),
    width: video['Width']&.to_i,
    height: video['Height']&.to_i,
    
    # HDR format detection
    hdr_format: video['HDR_Format'],
    hdr_format_version: video['HDR_Format_Version'],
    hdr_format_profile: video['HDR_Format_Profile'],
    hdr_format_level: video['HDR_Format_Level'],
    hdr_format_settings: video['HDR_Format_Settings'],
    hdr_format_compatibility: video['HDR_Format_Compatibility'],
    
    # Color space
    color_primaries: video['colour_primaries'],
    transfer_characteristics: video['transfer_characteristics'],
    matrix_coefficients: video['matrix_coefficients'],
    color_range: video['colour_range'],
    
    # Mastering display
    mastering_display_primaries: video['MasteringDisplay_ColorPrimaries'],
    mastering_display_luminance: video['MasteringDisplay_Luminance'],
    
    # Max light levels
    max_cll: video['MaxCLL'],
    max_fall: video['MaxFALL'],
    
    # Frame rate
    frame_rate: video['FrameRate']
  }
end

def format_bytes(bytes)
  return "" unless bytes
  
  units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  size = bytes.to_f
  unit_index = 0
  
  while size >= 1024 && unit_index < units.length - 1
    size /= 1024.0
    unit_index += 1
  end
  
  "%.1f %s" % [size, units[unit_index]]
end

# =============================================================================
# CONFIG GENERATION
# =============================================================================

def generate_config(streams, mediainfo, options)
  # Summary
  resolution = detect_resolution(mediainfo)
  hdr_info = detect_hdr(mediainfo)
  
  # Audio selection
  audio_streams = streams.select { |s| s['codec_type'] == 'audio' }
  selected_audio = select_audio_stream(audio_streams, streams)
  
  # Subtitle streams
  subtitle_streams = streams.each_with_index
    .select { |s, _| s['codec_type'] == 'subtitle' }
    .map { |_, idx| "0:#{idx}" }
  
  # Cover art
  has_cover_art = streams.any? { |s| ['mjpeg', 'png'].include?(s['codec_name']) }
  
  # HDR metadata
  if hdr_info[:is_sdr]
    color_primaries = ""
    color_trc = ""
    color_space = ""
    color_range = ""
    master_display = ""
    max_cll = ""
    max_fall = ""
  else
    color_primaries = normalize_color_primaries(mediainfo[:color_primaries])
    color_trc = normalize_transfer_characteristics(mediainfo[:transfer_characteristics])
    color_space = normalize_matrix_coefficients(mediainfo[:matrix_coefficients])
    color_range = normalize_color_range(mediainfo[:color_range])
    master_display = parse_master_display(
      mediainfo[:mastering_display_primaries],
      mediainfo[:mastering_display_luminance]
    )
    max_cll, max_fall = parse_max_light_levels(mediainfo[:max_cll], mediainfo[:max_fall])
  end
  
  # Build warnings
  warnings = build_warnings(selected_audio, hdr_info, streams)
  
  # Build config hash
  {
    'resolution' => resolution,
    'hdr' => hdr_info[:description],
    'file_size' => mediainfo[:file_size].to_s,
    'audio_description' => selected_audio[:description],
    'warnings' => warnings,
    'crf' => options[:crf],
    'preset' => options[:preset],
    'is_sdr' => hdr_info[:is_sdr],
    'color_primaries' => color_primaries,
    'color_trc' => color_trc,
    'color_space' => color_space,
    'color_range' => color_range,
    'master_display' => master_display,
    'max_cll' => max_cll,
    'max_fall' => max_fall,
    'has_dv' => hdr_info[:has_dv],
    'dv_profile_conversion_needed' => hdr_info[:dv_conversion_needed],
    'audio_stream' => selected_audio[:stream],
    'audio_action' => selected_audio[:action],
    'audio_convert_bitrate' => selected_audio[:bitrate],
    'has_subtitles' => !subtitle_streams.empty?,
    'subtitle_streams' => subtitle_streams,
    'has_cover_art' => has_cover_art
  }
end

def detect_resolution(mediainfo)
  height = mediainfo[:height]
  
  case height
  when 2160 then "4K 2160p"
  when 1080 then "1080p"
  when 720 then "720p"
  when 576 then "576p"
  when 480 then "480p"
  else
    width = mediainfo[:width]
    width && height ? "#{width}x#{height}" : "Unknown"
  end
end

def detect_hdr(mediainfo)
  hdr_format = mediainfo[:hdr_format].to_s
  hdr_compat = mediainfo[:hdr_format_compatibility].to_s
  hdr_profile = mediainfo[:hdr_format_profile].to_s
  transfer = mediainfo[:transfer_characteristics].to_s
  
  has_dv = hdr_format.include?('Dolby Vision')
  dv_conversion_needed = false
  
  description = if has_dv
    # Parse Dolby Vision profile
    if hdr_profile.include?('7.6') || hdr_profile.match?(/dvhe\.07/)
      dv_conversion_needed = true
      "DV Profile 7.6 + HDR10"
    elsif hdr_profile.include?('8.1') || hdr_profile.match?(/dvhe\.08/)
      "DV Profile 8.1 + HDR10"
    elsif hdr_profile.include?('8.4') || hdr_profile.match?(/dvhe\.08/)
      "DV Profile 8.4 + HDR10"
    elsif hdr_profile.include?('5')
      "DV Profile 5"
    else
      # Generic Dolby Vision
      "Dolby Vision + HDR10"
    end
  elsif hdr_format.include?('HDR10+') || hdr_compat.include?('HDR10+')
    "HDR10+"
  elsif hdr_format.include?('HDR10') || hdr_compat.include?('HDR10') || 
        transfer.include?('PQ') || transfer.include?('SMPTE ST 2084')
    "HDR10 only"
  elsif transfer.include?('HLG') || transfer.include?('ARIB STD-B67')
    "HLG"
  else
    "SDR"
  end
  
  {
    description: description,
    is_sdr: description == "SDR",
    has_dv: has_dv,
    dv_conversion_needed: dv_conversion_needed
  }
end

def normalize_color_primaries(primaries)
  return "bt2020" if primaries.nil? || primaries.empty?
  
  case primaries.downcase
  when /bt\.?2020/, /bt2020/
    "bt2020"
  when /bt\.?709/, /bt709/
    "bt709"
  when /smpte\s*170m/, /bt601/
    "smpte170m"
  when /smpte\s*240m/
    "smpte240m"
  when /dci\s*p3/, /display\s*p3/
    "bt2020"  # Map Display P3 to bt2020 for encoding
  else
    "bt2020"
  end
end

def normalize_transfer_characteristics(transfer)
  return "smpte2084" if transfer.nil? || transfer.empty?
  
  case transfer.downcase
  when /pq/, /smpte\s*st\s*2084/, /smpte2084/
    "smpte2084"
  when /hlg/, /arib\s*std-b67/
    "arib-std-b67"
  when /bt\.?709/, /bt709/
    "bt709"
  when /bt\.?601/, /bt601/
    "smpte170m"
  when /linear/
    "linear"
  when /srgb/, /iec.*61966/
    "iec61966-2-1"
  else
    "smpte2084"
  end
end

def normalize_matrix_coefficients(matrix)
  return "bt2020nc" if matrix.nil? || matrix.empty?
  
  case matrix.downcase
  when /bt\.?2020.*non.*constant/, /bt2020nc/, /bt2020_ncl/
    "bt2020nc"
  when /bt\.?2020.*constant/, /bt2020c/, /bt2020_cl/
    "bt2020c"
  when /bt\.?709/, /bt709/
    "bt709"
  when /bt\.?601/, /bt601/, /smpte\s*170m/
    "smpte170m"
  else
    "bt2020nc"
  end
end

def normalize_color_range(range)
  return "tv" if range.nil? || range.empty?
  
  case range.downcase
  when /limited/, /tv/
    "tv"
  when /full/, /pc/
    "pc"
  else
    "tv"
  end
end

def parse_master_display(primaries, luminance)
  return "" if primaries.nil? || primaries.empty?
  
  # Parse primaries from mediainfo format
  # Example: "Display P3" or "R: x=0.680 y=0.320, G: x=0.265 y=0.690, B: x=0.150 y=0.060, White point: x=0.3127 y=0.3290"
  
  # Check for common presets
  if primaries.include?('Display P3') || primaries.include?('DCI P3')
    # Display P3 primaries
    g = "G(13250,34500)"
    b = "B(7500,3000)"
    r = "R(34000,16000)"
    wp = "WP(15635,16450)"
  elsif primaries.include?('BT.2020') || primaries.include?('BT2020')
    # BT.2020 primaries
    g = "G(8500,39850)"
    b = "B(6550,2300)"
    r = "R(35400,14600)"
    wp = "WP(15635,16450)"
  else
    # Try to parse custom primaries
    # This is complex - for now, default to Display P3
    g = "G(13250,34500)"
    b = "B(7500,3000)"
    r = "R(34000,16000)"
    wp = "WP(15635,16450)"
  end
  
  # Parse luminance
  # Example: "min: 0.0050 cd/m2, max: 4000 cd/m2"
  if luminance
    min_lum = 50  # default 0.0050 cd/m2 in x265 format
    max_lum = 40000000  # default 4000 cd/m2 in x265 format
    
    if luminance =~ /min:\s*([\d.]+)/
      min_nits = $1.to_f
      min_lum = (min_nits * 10000).to_i
    end
    
    if luminance =~ /max:\s*([\d.]+)/
      max_nits = $1.to_f
      max_lum = (max_nits * 10000).to_i
    end
    
    l = "L(#{max_lum},#{min_lum})"
  else
    # Default: 4000 nits max, 0.005 nits min
    l = "L(40000000,50)"
  end
  
  "#{g}#{b}#{r}#{wp}#{l}"
end

def parse_max_light_levels(max_cll, max_fall)
  cll = "0"
  fall = "0"
  
  if max_cll && !max_cll.empty?
    # Parse "1000 cd/m2" or "1000, 400" format
    if max_cll.include?(',')
      parts = max_cll.split(',').map(&:strip)
      cll = parts[0].gsub(/[^\d]/, '')
      fall = parts[1]&.gsub(/[^\d]/, '') || "0"
    else
      cll = max_cll.gsub(/[^\d]/, '')
    end
  end
  
  if max_fall && !max_fall.empty? && fall == "0"
    fall = max_fall.gsub(/[^\d]/, '')
  end
  
  [cll.empty? ? "0" : cll, fall.empty? ? "0" : fall]
end

def select_audio_stream(audio_streams, all_streams)
  # Priority:
  # 1. Prefer English language
  # 2. DTS with explicit bit_rate → dts_core
  # 3. DTS with bit_rate=N/A (DTS-HD MA) → convert_ac3
  # 4. TrueHD/EAC3/Atmos → convert_ac3
  # 5. AC3 → copy
  # 6. AAC → copy
  
  return default_audio_response if audio_streams.empty?
  
  # Separate streams by codec
  dts_streams = audio_streams.select { |s| s['codec_name'] == 'dts' }
  ac3_streams = audio_streams.select { |s| s['codec_name'] == 'ac3' }
  eac3_streams = audio_streams.select { |s| s['codec_name'] == 'eac3' }
  truehd_streams = audio_streams.select { |s| s['codec_name'] == 'truehd' }
  aac_streams = audio_streams.select { |s| s['codec_name'] == 'aac' }
  
  # Priority 1: DTS with embedded core (has numeric bitrate)
  dts_with_core = find_best_audio(dts_streams) { |s| 
    s['bit_rate'] && s['bit_rate'] != 'N/A' && s['bit_rate'].to_i > 0 
  }
  
  if dts_with_core
    return build_audio_response(
      stream: dts_with_core,
      all_streams: all_streams,
      action: 'dts_core',
      reason: 'extracting DTS core for compatibility'
    )
  end
  
  # Priority 2: DTS-HD MA (no core, needs conversion)
  dts_hd_ma = find_best_audio(dts_streams) { |s| 
    !s['bit_rate'] || s['bit_rate'] == 'N/A' || s['bit_rate'].to_i == 0
  }
  
  if dts_hd_ma
    return build_audio_response(
      stream: dts_hd_ma,
      all_streams: all_streams,
      action: 'convert_ac3',
      reason: 'lossless audio, converting to AC3 640k as no DTS core present'
    )
  end
  
  # Priority 3: TrueHD or EAC3/Atmos
  truehd_or_atmos = find_best_audio(truehd_streams + eac3_streams)
  
  if truehd_or_atmos
    codec_desc = get_codec_description(truehd_or_atmos)
    return build_audio_response(
      stream: truehd_or_atmos,
      all_streams: all_streams,
      action: 'convert_ac3',
      reason: "converting #{codec_desc} to AC3 640k for compatibility"
    )
  end
  
  # Priority 4: AC3 (copy as-is)
  ac3_stream = find_best_audio(ac3_streams)
  
  if ac3_stream
    bitrate_desc = format_bitrate(ac3_stream['bit_rate'])
    return build_audio_response(
      stream: ac3_stream,
      all_streams: all_streams,
      action: 'copy',
      reason: "#{bitrate_desc}, copying as-is"
    )
  end
  
  # Priority 5: AAC (copy as-is)
  aac_stream = find_best_audio(aac_streams)
  
  if aac_stream
    bitrate_desc = format_bitrate(aac_stream['bit_rate'])
    return build_audio_response(
      stream: aac_stream,
      all_streams: all_streams,
      action: 'copy',
      reason: "#{bitrate_desc}, copying as-is"
    )
  end
  
  # Fallback: pick any audio stream
  best_stream = find_best_audio(audio_streams)
  if best_stream
    return build_audio_response(
      stream: best_stream,
      all_streams: all_streams,
      action: 'copy',
      reason: 'copying as-is'
    )
  end
  
  default_audio_response
end

def find_best_audio(streams, &filter)
  return nil if streams.empty?
  
  # Apply filter if provided
  filtered = filter ? streams.select(&filter) : streams
  return nil if filtered.empty?
  
  # Prefer English language
  english = filtered.select { |s| 
    lang = s['language'].to_s.downcase
    lang.start_with?('en') || lang == 'eng' || lang == 'english'
  }
  
  candidates = english.any? ? english : filtered
  
  # Sort by channel count (descending), then by bitrate (descending)
  candidates.max_by do |s|
    channels = s['channels'] || 0
    bitrate = parse_bitrate(s['bit_rate'])
    [channels, bitrate]
  end
end

def parse_bitrate(bitrate_str)
  return 0 if bitrate_str.nil? || bitrate_str == 'N/A'
  
  # Handle both string and integer inputs
  bitrate_str.to_s.gsub(/[^\d]/, '').to_i
end

def format_bitrate(bitrate_str)
  bitrate = parse_bitrate(bitrate_str)
  return "unknown bitrate" if bitrate == 0
  
  if bitrate >= 1_000_000
    "%.1f Mbps" % (bitrate / 1_000_000.0)
  elsif bitrate >= 1_000
    "%d kbps" % (bitrate / 1_000)
  else
    "#{bitrate} bps"
  end
end

def get_codec_description(stream)
  codec = stream['codec_name'].to_s.upcase
  channels = stream['channels'] || 0
  title = stream['title'].to_s
  
  # Check for Atmos in title
  if title.match?(/atmos/i) && codec == 'EAC3'
    return "Dolby Atmos"
  elsif title.match?(/atmos/i) && codec == 'TRUEHD'
    return "Dolby TrueHD Atmos"
  end
  
  # Standard codec names
  case codec
  when 'DTS'
    if title.match?(/dts-hd\s*ma/i) || title.match?(/dts-hd\s*master/i)
      "DTS-HD MA"
    elsif title.match?(/dts-hd/i)
      "DTS-HD"
    else
      "DTS"
    end
  when 'TRUEHD'
    "Dolby TrueHD"
  when 'EAC3'
    "E-AC-3"
  when 'AC3'
    "AC-3"
  when 'AAC'
    "AAC"
  else
    codec
  end
end

def get_channel_description(channels)
  return "unknown channels" if channels.nil? || channels == 0
  
  # LFE is typically included in channel count
  if channels >= 6
    "#{channels - 1}.1"
  elsif channels == 2
    "2.0"
  elsif channels == 1
    "1.0"
  else
    "#{channels}.0"
  end
end

def build_audio_response(stream:, all_streams:, action:, reason:)
  # Find the actual stream index in the full stream list
  stream_index = all_streams.index(stream)
  
  codec_desc = get_codec_description(stream)
  channel_desc = get_channel_description(stream['channels'])
  lang = stream['language'] || 'unknown'
  
  # Build description
  description_parts = ["#{codec_desc} #{channel_desc}"]
  description_parts << "(stream 0:#{stream_index})" if stream_index
  
  # Add bitrate for DTS/AC3
  if ['dts', 'ac3', 'eac3'].include?(stream['codec_name'])
    bitrate = parse_bitrate(stream['bit_rate'])
    if bitrate > 0
      description_parts << format_bitrate(stream['bit_rate'])
    end
  end
  
  description_parts << reason
  
  {
    stream: stream_index ? "0:#{stream_index}" : "0:1",
    action: action,
    bitrate: '640k',
    description: description_parts.join(' - ')
  }
end

def default_audio_response
  {
    stream: "0:1",
    action: 'copy',
    bitrate: '640k',
    description: "No suitable audio stream found - copying first audio stream"
  }
end

def build_warnings(audio, hdr_info, streams)
  warnings = []
  
  # Audio warnings
  if audio[:action] == 'convert_ac3' && audio[:description].include?('DTS-HD MA')
    warnings << "DTS-HD MA stream has bit_rate=N/A (no embedded DTS core), will convert to AC3"
  end
  
  # Check if we have English audio
  audio_streams = streams.select { |s| s['codec_type'] == 'audio' }
  has_english = audio_streams.any? { |s| 
    lang = s['language'].to_s.downcase
    lang.start_with?('en') || lang == 'eng' || lang == 'english'
  }
  
  unless has_english
    warnings << "No English audio track found - using #{audio_streams.first&.[]('language') || 'unknown'} language track"
  end
  
  # HDR warnings
  if hdr_info[:dv_conversion_needed]
    warnings << "Dolby Vision Profile 7.6 detected - requires dovi_tool conversion to Profile 8.1"
  end
  
  # Subtitle warnings
  subtitle_streams = streams.select { |s| s['codec_type'] == 'subtitle' }
  if subtitle_streams.empty?
    warnings << "No subtitle streams found"
  end
  
  warnings
end

# =============================================================================
# MAIN
# =============================================================================

puts
puts c('=' * 60, C::BOLD)
puts c('  analyse_local.rb — Local Media File Analyser', C::BOLD, C::WHITE)
puts c('  Generates YAML config directly (no Claude needed)', C::DIM)
puts c('=' * 60, C::BOLD)
puts
puts c("  File:   #{File.basename(input)}", C::DIM)
puts c("  CRF:    #{options[:crf]}", C::DIM)
puts c("  Preset: #{options[:preset]}", C::DIM)

# Check dependencies
log_section("Checking dependencies")
%w[ffprobe mediainfo].each do |cmd|
  command_exists?(cmd) ? log_ok(cmd) : log_error("#{cmd} not found — please install it")
end

# Run analysis
log_section("Analysing file")
streams = parse_ffprobe(input)
mediainfo = parse_mediainfo(input)
log_ok("Analysis complete")

# Generate config
log_section("Generating config")
config = generate_config(streams, mediainfo, options)
log_ok("Config generated")

# Save config
output_path = options[:output] || "#{basename}_config.yaml"
File.write(output_path, "---\n" + config.to_yaml.lines[1..-1].join)

# Done
log_section("Done")
log_ok("Config saved to: #{output_path}")

puts
puts c('=' * 60, C::BOLD)
puts c('  Next step:', C::BOLD, C::WHITE)
puts c('=' * 60, C::BOLD)
puts
puts "  Run the encoder:"
puts "     #{c("ruby encode.rb --file \"#{File.basename(input)}\" --config \"#{output_path}\"", C::GREEN)}"
puts
