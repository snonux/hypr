#!/usr/bin/env ruby
# frozen_string_literal: true

# photo-enhance.rb — AI photo enhancer via ComfyUI on a Hyperstack GPU VM.
#
# Submits images from --indir to the ComfyUI REST API, downloads the AI-enhanced
# results and saves alongside the originals with an _e suffix.  Also downloads
# a per-photo JSON metadata file written by the WritePhotoMetadata ComfyUI node
# and converts it to a human-readable .md report alongside each enhanced photo.
#
# AI pipeline (ComfyUI, GPU):
#   1. Real-ESRGAN realesr-general-x4v3  — 4× upscale at full 4K input, AI denoise
#   2. CodeFormer fidelity=0.7           — neural face restoration
#   3. CLIP ViT-B/32                     — scene classification (portrait/landscape/…)
#   4. AdaptivePhotoGrade                — scene-tuned exposure/contrast/saturation/detail
#   5. SkyEnhance                        — HSV sky mask + graduated sky correction
#   6. Depth Anything V2 Small           — depth map → foreground sharp, background soft
#
# Usage:
#   ruby photo-enhance.rb --config hyperstack-vm-photo.toml \
#     --indir ~/Pictures [--watch] [--workflow workflows/photo-enhance.json]
#
# Requirements:
#   - ComfyUI VM: ruby hyperstack.rb --config hyperstack-vm-photo.toml create
#   - WireGuard tunnel active (wg1)

begin
  require 'bundler/setup'
rescue LoadError, Gem::GemNotFoundException, Gem::LoadError, Errno::ENOENT
  nil
end

require 'json'
require 'net/http'
require 'optparse'
require 'fileutils'
require 'digest'
require 'time'
require 'set'

begin
  require 'toml-rb'
rescue LoadError
  warn "Missing dependency: toml-rb. Run `bundle install` in #{__dir__} first."
  exit 2
end

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class PhotoConfig
  attr_reader :host, :port, :workflow_path

  def initialize(config_path, workflow_path_override)
    raw       = TomlRB.load_file(File.expand_path(config_path))
    hostname  = raw.dig('vm', 'hostname') || 'hyperstack-photo'
    interface = raw.dig('local_client', 'interface_name') || 'wg1'
    @host     = "#{hostname}.#{interface}"
    @port     = Integer(raw.dig('comfyui', 'port') || 8188)
    @workflow_path = workflow_path_override ||
                     File.join(File.dirname(File.expand_path(config_path)), 'workflows', 'photo-enhance.json')
  end
end

# ---------------------------------------------------------------------------
# ComfyUI API client — upload, submit, poll, download.
# ---------------------------------------------------------------------------

class ComfyUIClient
  POLL_INTERVAL_SEC    = 2
  POLL_TIMEOUT_SEC     = 300  # 5 minutes; ESRGAN is fast on GPU
  # When ComfyUI crashes (OOM), systemd restarts it in ~30s.
  # We poll until reachable again, up to this many seconds total.
  RECOVERY_TIMEOUT_SEC = 300
  RECOVERY_POLL_SEC    = 10

  def initialize(host:, port:, out: $stdout)
    @host = host
    @port = port
    @out  = out
  end

  def upload_image(file_path)
    filename   = File.basename(file_path)
    image_data = File.binread(file_path)
    boundary   = "----RubyPhotoEnhance#{hex(8)}"
    body = [
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"image\"; filename=\"#{filename}\"\r\n",
      "Content-Type: #{mime_type(file_path)}\r\n\r\n",
      image_data,
      "\r\n--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n",
      "--#{boundary}--\r\n"
    ].join
    resp = post_raw('/upload/image', body, "multipart/form-data; boundary=#{boundary}")
    raise "Upload failed (#{resp.code}): #{resp.body}" unless resp.code == '200'
    JSON.parse(resp.body)['name'] || filename
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
    raise "Cannot reach ComfyUI at #{@host}:#{@port} — is WireGuard active? (#{e.message})"
  end

  def submit_prompt(workflow)
    resp = post_json('/prompt', { 'prompt' => workflow })
    raise "Prompt failed (#{resp.code}): #{resp.body}" unless resp.code == '200'
    JSON.parse(resp.body)['prompt_id'] or raise "No prompt_id in: #{resp.body}"
  end

  def wait_for_output(prompt_id)
    deadline = Time.now + POLL_TIMEOUT_SEC
    loop do
      raise "Timed out after #{POLL_TIMEOUT_SEC}s for #{prompt_id}" if Time.now > deadline

      resp   = get("/history/#{prompt_id}")
      raise "History poll failed (#{resp.code})" unless resp.code == '200'

      result = JSON.parse(resp.body)[prompt_id]
      if result
        outputs = extract_filenames(result)
        return outputs unless outputs.empty?

        # ComfyUI cached the run (identical inputs) and wrote no new files — bail fast.
        status = result.dig('status', 'status_str')
        raise "ComfyUI cached execution returned no outputs for #{prompt_id}" \
          if result.dig('status', 'completed') && status == 'success'
      end

      sleep POLL_INTERVAL_SEC
    end
  end

  def download_output(filename, dest_path)
    resp = get("/view?filename=#{URI.encode_www_form_component(filename)}&type=output&subfolder=")
    raise "Download failed (#{resp.code}) for #{filename}" unless resp.code == '200'
    FileUtils.mkdir_p(File.dirname(dest_path))
    File.binwrite(dest_path, resp.body)
  end

  def check_connectivity!
    resp = get('/system_stats')
    raise "Health check failed (#{resp.code}): #{resp.body}" unless resp.code == '200'
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
    raise "Cannot reach ComfyUI at #{@host}:#{@port} — is WireGuard active? (#{e.message})"
  end

  # Polls ComfyUI until it responds again (or times out).
  # Called automatically when an upload or submit fails with a connection error.
  # ComfyUI crashes on OOM (large ESRGAN tensors) and systemd restarts it in ~30s.
  # Returns true if recovered, raises on timeout.
  def wait_for_recovery
    @out.puts "  ComfyUI unreachable — waiting for restart (up to #{RECOVERY_TIMEOUT_SEC}s)..."
    deadline = Time.now + RECOVERY_TIMEOUT_SEC
    start    = Time.now
    loop do
      raise "ComfyUI did not recover within #{RECOVERY_TIMEOUT_SEC}s — giving up" if Time.now > deadline

      sleep RECOVERY_POLL_SEC
      begin
        get('/system_stats')
        @out.puts '  ComfyUI recovered — resuming'
        return true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout
        @out.puts "  still waiting... (#{(Time.now - start).round}s elapsed)"
      end
    end
    raise "ComfyUI did not recover within #{RECOVERY_TIMEOUT_SEC}s — giving up"
  end

  private

  def extract_filenames(result)
    Array(result.dig('outputs'))
      .flat_map { |_id, node| Array(node['images']) }
      .map { |img| img['filename'] }
      .compact.reject(&:empty?)
  end

  def get(path)
    Net::HTTP.get_response(URI("http://#{@host}:#{@port}#{path}"))
  end

  def post_json(path, payload)
    uri = URI("http://#{@host}:#{@port}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(payload)
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def post_raw(path, body, content_type)
    uri = URI("http://#{@host}:#{@port}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = content_type
    req.body = body
    Net::HTTP.start(uri.host, uri.port, read_timeout: 120) { |h| h.request(req) }
  end

  def mime_type(path)
    case File.extname(path).downcase
    when '.jpg', '.jpeg' then 'image/jpeg'
    when '.png'          then 'image/png'
    when '.webp'         then 'image/webp'
    else 'application/octet-stream'
    end
  end

  def hex(n)
    Digest::SHA256.hexdigest(Time.now.to_f.to_s + rand.to_s)[0, n * 2]
  end
end

# ---------------------------------------------------------------------------
# Manifest — avoids re-processing files across runs and in watch mode.
# ---------------------------------------------------------------------------

class ProcessedManifest
  FILE_NAME = '.photo-enhance-processed'

  def initialize(dir)
    @path    = File.join(dir, FILE_NAME)
    @entries = load_entries
  end

  def processed?(file_path)
    @entries.include?(digest(file_path))
  end

  def mark_done(file_path)
    key = digest(file_path)
    @entries << key
    File.open(@path, 'a') { |f| f.puts(key) }
  end

  private

  def load_entries
    return Set.new unless File.exist?(@path)
    File.readlines(@path, chomp: true).map(&:strip).reject(&:empty?).to_set
  end

  # Covers basename + size + mtime so a re-shot of the same filename re-processes.
  def digest(file_path)
    stat = File.stat(file_path)
    Digest::SHA256.hexdigest("#{File.basename(file_path)}:#{stat.size}:#{stat.mtime.to_i}")
  rescue Errno::ENOENT
    Digest::SHA256.hexdigest(File.basename(file_path))
  end
end

# ---------------------------------------------------------------------------
# Enhancer — orchestrates upload → AI → download → colour correct per image.
# ---------------------------------------------------------------------------

class PhotoEnhancer
  SUPPORTED_EXTENSIONS = %w[.jpg .jpeg .png .webp].freeze

  # No colour corrections — pure AI output from Real-ESRGAN is used as-is.
  # ImageMagick is only used to bake EXIF rotation and convert PNG→JPEG.
  COLOR_ARGS = [].freeze

  def initialize(config:, client:, workflow:, indir:, manifest:, out: $stdout)
    @config   = config
    @client   = client
    @workflow = workflow
    @indir    = indir
    @manifest = manifest
    @out      = out
  end

  def run(watch: false)
    @client.check_connectivity!
    @out.puts "ComfyUI ready at http://#{@config.host}:#{@config.port}"
    @out.puts "Enhancing photos in #{@indir}"
    @out.puts watch ? '(watch mode — Ctrl-C to stop)' : ''

    loop do
      find_pending.each { |path| enhance_one(path) }
      break unless watch
      sleep 5
    end
  end

  private

  def find_pending
    Dir.glob(File.join(@indir, '*'))
       .select { |f| File.file?(f) && SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase) }
       .reject { |f| File.basename(f, '.*').end_with?('_e') }
       .reject { |f| File.basename(f).include?('.orient.') }
       .reject { |f| @manifest.processed?(f) }
       .sort
  end

  def enhance_one(src_path)
    ext       = File.extname(src_path).downcase
    basename  = File.basename(src_path, File.extname(src_path))
    dest_path = File.join(File.dirname(src_path), "#{basename}_e#{ext}")

    @out.puts "[#{Time.now.strftime('%H:%M:%S')}] #{File.basename(src_path)}"

    # Bake in EXIF rotation before uploading — ComfyUI strips EXIF metadata.
    upload_path = auto_orient_tempfile(src_path)

    retried = false
    begin
      uploaded_name = @client.upload_image(upload_path)
      workflow      = inject_input(@workflow, uploaded_name)
      prompt_id     = @client.submit_prompt(workflow)
      @out.puts "  prompt #{prompt_id}"

      filenames = @client.wait_for_output(prompt_id)
      raise "No outputs returned for #{src_path}" if filenames.empty?
    rescue RuntimeError => e
      # On connection refused (ComfyUI crashed / OOM), wait for systemd to restart
      # it and retry this photo once. Any other error propagates immediately.
      if !retried && e.message.include?('Cannot reach ComfyUI')
        retried = true
        @client.wait_for_recovery
        retry
      end
      raise
    end

    # ComfyUI outputs PNG; download then convert to original format.
    tmp_png = "#{dest_path}.tmp.png"
    @client.download_output(filenames.first, tmp_png)
    save_with_corrections(tmp_png, dest_path, ext)
    File.delete(tmp_png) if File.exist?(tmp_png)
    File.delete(upload_path) if upload_path != src_path && File.exist?(upload_path)

    # Restore original EXIF metadata onto the enhanced JPEG.
    # ComfyUI strips all EXIF when it processes the image; this brings back
    # capture time, camera/lens info, ICC profile, and GPS coordinates.
    copy_exif(src_path, dest_path)

    # Download the JSON metadata written by WritePhotoMetadata and render it
    # as a human-readable .md report alongside the enhanced photo.
    # ComfyUI appends _NNNNN_ counter: "enhanced_abc123__00001_.png" → "enhanced_abc123_"
    prefix = filenames.first.sub(/_\d+_\.png$/, '')
    meta_file = "#{prefix}meta.json"
    md_path   = File.join(File.dirname(dest_path),
                          "#{File.basename(dest_path, File.extname(dest_path))}.md")
    download_and_write_md(meta_file, src_path, dest_path, md_path, prompt_id)

    @manifest.mark_done(src_path)
    @out.puts "  -> #{dest_path} (#{kb(src_path)} KB -> #{kb(dest_path)} KB)"
  rescue StandardError => e
    @out.puts "  ERROR #{File.basename(src_path)}: #{e.message}"
  end

  # Run magick -auto-orient into a temp file so EXIF rotation is baked in.
  # Falls back to the original path if magick is unavailable.
  def auto_orient_tempfile(src_path)
    ext = File.extname(src_path)
    tmp = "#{src_path}.orient#{ext}"
    return tmp if system('magick', src_path, '-auto-orient', tmp) && File.exist?(tmp)

    @out.puts "  Warning: auto-orient failed, uploading original"
    src_path
  end

  # Convert the downloaded PNG to the target format (JPEG quality 92 for .jpg).
  # No colour processing — pure AI output from Real-ESRGAN is preserved as-is.
  def save_with_corrections(src_png, dest_path, ext)
    quality_args = ext.match?(/\.jpe?g/) ? ['-quality', '92'] : []
    system('magick', src_png, *COLOR_ARGS, *quality_args, dest_path)
  end

  # Copy selected EXIF fields from the original source file to the enhanced JPEG.
  # ComfyUI strips all metadata during inference; this restores capture time,
  # camera/lens info, ICC profile, and GPS so the output is a proper derivative.
  # Thumbnail and PreviewImage are excluded — they would show the un-enhanced original.
  def copy_exif(src_path, dest_path)
    return unless dest_path.match?(/\.jpe?g$/i)
    return unless system('which', 'exiftool', out: File::NULL, err: File::NULL)

    # Copy all EXIF/IPTC/GPS/ICC tags from source, skipping embedded previews
    unless system(
      'exiftool',
      '-TagsFromFile', src_path,
      '-all:all',
      '--ThumbnailImage',  # skip old thumbnail (shows un-enhanced photo)
      '--PreviewImage',    # skip full preview too
      '-overwrite_original',
      dest_path,
      out: File::NULL, err: File::NULL
    )
      @out.puts "  Warning: exiftool copy_exif failed for #{File.basename(dest_path)}"
      return
    end

    # Tag the output as a derived image so viewers know it was processed
    system(
      'exiftool',
      '-overwrite_original',
      '-Software=photo-enhance (Real-ESRGAN + ComfyUI)',
      dest_path,
      out: File::NULL, err: File::NULL
    )
  end

  # Download the WritePhotoMetadata JSON from ComfyUI output and render it
  # as a Markdown report saved alongside the enhanced photo.
  # prompt_id is included in the report for reproducibility and crash recovery.
  def download_and_write_md(meta_filename, src_path, dest_path, md_path, prompt_id = nil)
    resp = @client.send(:get,
      "/view?filename=#{URI.encode_www_form_component(meta_filename)}&type=output&subfolder=")
    return unless resp.code == '200'

    meta         = JSON.parse(resp.body)
    profile      = meta['enhancement_profile'] || {}
    sky          = meta['sky']                  || {}
    depth        = meta['depth_sharpen']        || {}
    models       = meta['models']               || {}
    scene        = meta['scene_type']  || 'unknown'
    esrgan_mode  = meta['esrgan_mode'] || 'full'
    scene_scores = meta['scene_scores'] || {}
    ts           = meta['generated_at'] || Time.now.utc.iso8601

    # Format top-3 scene confidence scores as "landscape 55%, golden_hour 35%, overcast 10%"
    scores_str = scene_scores
      .sort_by { |_, v| -v }
      .map { |s, v| "#{s} #{(v * 100).round}%" }
      .join(', ')

    md = <<~MD
      # #{File.basename(dest_path)} — Enhancement Report

      **Source:** #{File.basename(src_path)} (#{kb(src_path)} KB)
      **Enhanced:** #{File.basename(dest_path)} (#{kb(dest_path)} KB)
      **Processed:** #{ts}
      **ComfyUI prompt ID:** #{prompt_id || 'n/a'}

      ## AI Pipeline

      | Step | Model / Node | Device | What it does |
      |------|-------------|--------|--------------|
      | 1 | `#{models['scene_detect']}` | GPU | Zero-shot scene classification → ESRGAN gating |
      | 2 | `#{models['upscaler']}` (#{esrgan_mode}) | GPU | 4× upscale at full 4K input → 16K → back to 4K |
      | 3 | `#{models['face_restore']}` | GPU | Face detection + neural restoration |
      | 4 | Adaptive Photo Grade | CPU | Scene-blended exposure / contrast / saturation / detail |
      | 5 | Sky Enhance | CPU | HSV sky mask + graduated sky correction |
      | 6 | `#{models['depth']}` | GPU | Depth map → foreground sharpening |

      ## Scene Detection

      | | |
      |-|-|
      | **Detected scene** | #{scene} |
      | **Top-3 scores** | #{scores_str.empty? ? 'n/a' : scores_str} |
      | **ESRGAN mode** | #{esrgan_mode} (skip=portrait/night, weak=indoor/golden, full=landscape/beach) |

      ## Colour Grading Profile (blended)

      | Setting | Value |
      |---------|-------|
      | Exposure | +#{profile['exposure_stops']} stops |
      | Contrast | #{profile['contrast_factor']}× |
      | Saturation | #{profile['saturation_mult']}× |
      | Detail / Clarity | #{profile['detail_mult']}× |
      | Denoise strength | #{profile['denoise_strength']} |

      ## Sky Enhancement

      | Setting | Value |
      |---------|-------|
      | Sky coverage | #{sky['coverage_pct']}% of image |
      | Sky exposure | +#{sky['sky_exposure']} stops |
      | Sky saturation | #{sky['sky_saturation']}× |

      ## Depth-Guided Sharpening

      | Setting | Value |
      |---------|-------|
      | Foreground sharpening | #{depth['foreground_sharpen']}× |
      | Background blur | #{depth['background_blur']} (0.0 = disabled) |
    MD

    File.write(md_path, md)
  rescue StandardError => e
    @out.puts "  Warning: could not write metadata report: #{e.message}"
  end

  # Inject the upload filename and a unique prefix into LoadImage, SaveImage,
  # and WritePhotoMetadata to bust ComfyUI's cache and link metadata to image.
  def inject_input(workflow, filename)
    wf     = JSON.parse(JSON.generate(workflow))  # deep dup
    prefix = "enhanced_#{Digest::SHA256.hexdigest(Time.now.to_f.to_s + rand.to_s)[0, 8]}_"
    wf.each_value do |node|
      next unless node.is_a?(Hash)
      case node['class_type']
      when 'LoadImage'          then node['inputs']['image']           = filename
      when 'SaveImage'          then node['inputs']['filename_prefix'] = prefix
      when 'WritePhotoMetadata'
        node['inputs']['filename_prefix'] = prefix
        node['inputs']['source_filename'] = filename
      end
    end
    wf
  end

  def kb(path)
    (File.size(path) / 1024.0).round
  end
end

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

options = {
  config:   File.join(__dir__, 'hyperstack-vm-photo.toml'),
  indir:    nil,
  watch:    false,
  workflow: nil,
  test:     false
}

OptionParser.new do |o|
  o.banner = 'Usage: ruby photo-enhance.rb [options]'
  o.on('--config PATH',   'TOML config (default: hyperstack-vm-photo.toml)') { |v| options[:config]   = v }
  o.on('--indir PATH',    'Directory of photos to enhance')                   { |v| options[:indir]    = v }
  o.on('--workflow PATH', 'ComfyUI workflow JSON override')                   { |v| options[:workflow] = v }
  o.on('--watch',         'Keep running, process new images as they arrive')  { options[:watch] = true }
  o.on('--test',          'Check ComfyUI connectivity only, then exit')       { options[:test]  = true }
  o.on('-h', '--help',    'Show this help') { puts o; exit }
end.parse!

abort "Config not found: #{options[:config]}" unless File.exist?(options[:config])

cfg    = PhotoConfig.new(options[:config], options[:workflow])
client = ComfyUIClient.new(host: cfg.host, port: cfg.port)

if options[:test]
  begin
    client.check_connectivity!
    puts "ComfyUI reachable at http://#{cfg.host}:#{cfg.port} — OK"
    exit 0
  rescue RuntimeError => e
    warn "ERROR: #{e.message}"; exit 1
  end
end

abort '--indir is required' unless options[:indir]
indir = File.expand_path(options[:indir])
abort "Directory not found: #{indir}" unless File.directory?(indir)
abort "Workflow not found: #{cfg.workflow_path}" unless File.exist?(cfg.workflow_path)

workflow = JSON.parse(File.read(cfg.workflow_path))
manifest = ProcessedManifest.new(indir)
enhancer = PhotoEnhancer.new(config: cfg, client: client, workflow: workflow,
                              indir: indir, manifest: manifest)
begin
  enhancer.run(watch: options[:watch])
rescue RuntimeError => e
  warn "ERROR: #{e.message}"; exit 1
rescue Interrupt
  puts "\nStopped."
end
