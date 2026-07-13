#!/usr/bin/env ruby
# Usage: ruby video_dir_info.rb [--all] /path/to/folder
#
# For each subdirectory of the given folder, shows total size, media file
# count, and video codec(s), sorted largest to smallest.
#
# By default only the largest media file per folder is probed for its codec.
# Pass --all (or -a) to probe every media file.

require "open3"
require "json"

MEDIA_EXTENSIONS = %w[.mkv .mp4 .m4v .avi .mov .wmv .ts .m2ts .webm .flv .mpg .mpeg .vob].freeze

def die(msg)
  warn msg
  exit 1
end

probe_all = !(ARGV.delete("--all") || ARGV.delete("-a")).nil?
dir = ARGV[0] or die "Usage: #{$PROGRAM_NAME} [--all] <folder>"
die "Not a directory: #{dir}" unless File.directory?(dir)

def human_size(bytes)
  units = %w[B KB MB GB TB]
  size = bytes.to_f
  unit = 0
  while size >= 1024 && unit < units.size - 1
    size /= 1024
    unit += 1
  end
  format("%.2f %s", size, units[unit])
end

def media_file?(path)
  MEDIA_EXTENSIONS.include?(File.extname(path).downcase)
end

def human_bitrate(bits_per_sec)
  if bits_per_sec >= 1_000_000
    format("%.1f Mbps", bits_per_sec / 1_000_000.0)
  else
    format("%d kbps", bits_per_sec / 1_000)
  end
end

def probe(path)
  out, _err, status = Open3.capture3(
    "ffprobe", "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "stream=codec_name,width,height,bit_rate",
    "-show_entries", "format=bit_rate,duration",
    "-of", "json",
    path
  )
  return nil unless status.success?

  data = JSON.parse(out)
  stream = data["streams"]&.first or return nil
  codec = stream["codec_name"]
  return nil if codec.nil? || codec.empty?

  width, height = stream.values_at("width", "height")
  resolution = width && height ? "#{width}x#{height}" : nil

  # Prefer the video stream's own bitrate; MKVs often omit it, so fall back to
  # the container bitrate (includes audio), then to file size / duration.
  bitrate = stream["bit_rate"].to_i
  bitrate = data.dig("format", "bit_rate").to_i if bitrate <= 0
  if bitrate <= 0
    duration = data.dig("format", "duration").to_f
    bitrate = (File.size(path) * 8 / duration).to_i if duration > 0
  end

  { codec: codec, resolution: resolution, bitrate: bitrate > 0 ? bitrate : nil }
rescue JSON::ParserError, Errno::ENOENT
  nil
end

ffprobe_available = system("which ffprobe > /dev/null 2>&1")
warn "warning: ffprobe not found, codec detection disabled" unless ffprobe_available

subdirs = Dir.children(dir).sort.select { |e| File.directory?(File.join(dir, e)) }

rows = subdirs.each_with_index.map do |entry, i|
  percent = (i * 100) / subdirs.size
  $stderr.print "\rScanning [#{i + 1}/#{subdirs.size}] #{percent}% #{entry}\e[K"

  subdir = File.join(dir, entry)
  size = 0
  media_files = []
  Dir.glob(File.join(subdir, "**", "*"), File::FNM_DOTMATCH).each do |f|
    next unless File.file?(f)
    size += File.size(f)
    media_files << f if media_file?(f)
  end

  probed =
    if ffprobe_available
      to_probe = probe_all ? media_files : [media_files.max_by { |f| File.size(f) }].compact
      to_probe.filter_map { |f| probe(f) }
    else
      []
    end
  codecs = probed.map { |p| p[:codec] }.uniq.sort
  resolutions = probed.filter_map { |p| p[:resolution] }.uniq.sort
  bitrates = probed.filter_map { |p| p[:bitrate] }.sort.reverse.map { |b| human_bitrate(b) }.uniq

  {
    name: entry,
    size: size,
    media_count: media_files.size,
    codecs: codecs.empty? ? "-" : codecs.join(", "),
    resolutions: resolutions.empty? ? "-" : resolutions.join(", "),
    bitrates: bitrates.empty? ? "-" : bitrates.join(", ")
  }
end

$stderr.print "\r\e[K" unless subdirs.empty?

rows.sort_by! { |r| -r[:size] }

headers = ["Folder", "Size", "Media Files", "Codec", "Resolution", "Bitrate"]
table = rows.map { |r| [r[:name], human_size(r[:size]), r[:media_count].to_s, r[:codecs], r[:resolutions], r[:bitrates]] }
widths = headers.each_index.map do |i|
  ([headers[i]] + table.map { |row| row[i] }).map(&:length).max
end

separator = "+-" + widths.map { |w| "-" * w }.join("-+-") + "-+"
format_row = ->(row) do
  "| " + row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join(" | ") + " |"
end

puts separator
puts format_row.call(headers)
puts separator
table.each { |row| puts format_row.call(row) }
puts separator

total_size = rows.sum { |r| r[:size] }
total_media = rows.sum { |r| r[:media_count] }
puts "#{rows.size} folders, #{total_media} media files, #{human_size(total_size)} total"
