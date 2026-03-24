#!/usr/bin/env ruby
# frozen_string_literal: true

# photo-enhance.rb — Photolemur-style automatic photo enhancer via ComfyUI.
#
# Submits images from --indir to the ComfyUI REST API running on a Hyperstack VM,
# downloads the enhanced results to --outdir, and optionally watches for new files.
#
# Usage:
#   ruby photo-enhance.rb --config hyperstack-vm-photo.toml \
#     --indir ~/Pictures --outdir ~/Pictures/enhanced [--watch] [--workflow workflows/photo-enhance.json]
#
# Requirements:
#   - ComfyUI VM provisioned with: ruby hyperstack.rb --config hyperstack-vm-photo.toml create
#   - WireGuard tunnel active (wg1): verified via curl http://hyperstack-photo.wg1:8188/system_stats
#   - Ruby stdlib only (no extra gems needed).

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

begin
  require 'toml-rb'
rescue LoadError
  warn "Missing dependency: toml-rb. Run `bundle install` in #{__dir__} first."
  exit 2
end

# ---------------------------------------------------------------------------
# Config loading — reads only the fields photo-enhance.rb needs from the TOML.
# ---------------------------------------------------------------------------

class PhotoConfig
  attr_reader :host, :port, :workflow_path

  def initialize(config_path, workflow_path_override)
    raw = TomlRB.load_file(File.expand_path(config_path))
    hostname = raw.dig('vm', 'hostname') || 'hyperstack-photo'
    interface = raw.dig('local_client', 'interface_name') || 'wg1'
    @host = "#{hostname}.#{interface}"
    @port = Integer(raw.dig('comfyui', 'port') || 8188)
    @workflow_path = workflow_path_override ||
                     File.join(File.dirname(File.expand_path(config_path)), 'workflows', 'photo-enhance.json')
  end
end

# ---------------------------------------------------------------------------
# ComfyUI API client — upload, submit, poll, download.
# ---------------------------------------------------------------------------

class ComfyUIClient
  POLL_INTERVAL_SEC = 2
  POLL_TIMEOUT_SEC  = 600  # 10 minutes per image (SUPIR can be slow on first load)

  def initialize(host:, port:, out: $stdout)
    @host = host
    @port = port
    @out  = out
  end

  # Upload a local image file; returns the filename ComfyUI assigned it.
  def upload_image(file_path)
    filename = File.basename(file_path)
    image_data = File.binread(file_path)
    boundary = "----RubyPhotoEnhance#{SecureRandom_hex(8)}"

    body = [
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"image\"; filename=\"#{filename}\"\r\n",
      "Content-Type: #{mime_type_for(file_path)}\r\n\r\n",
      image_data,
      "\r\n--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n",
      "--#{boundary}--\r\n"
    ].join

    resp = post_raw('/upload/image', body, "multipart/form-data; boundary=#{boundary}")
    raise "Upload failed (HTTP #{resp.code}): #{resp.body}" unless resp.code == '200'

    JSON.parse(resp.body)['name'] || filename
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
    raise "Cannot reach ComfyUI at #{@host}:#{@port} — is WireGuard (wg1) active? (#{e.message})"
  end

  # Submit a workflow; returns the prompt_id string.
  def submit_prompt(workflow)
    resp = post_json('/prompt', { 'prompt' => workflow })
    raise "Prompt submission failed (HTTP #{resp.code}): #{resp.body}" unless resp.code == '200'

    JSON.parse(resp.body)['prompt_id'] or raise "No prompt_id in response: #{resp.body}"
  end

  # Poll until the prompt finishes; returns the list of output filenames.
  def wait_for_output(prompt_id)
    deadline = Time.now + POLL_TIMEOUT_SEC
    loop do
      raise "Timed out after #{POLL_TIMEOUT_SEC}s waiting for prompt #{prompt_id}" if Time.now > deadline

      resp = get("/history/#{prompt_id}")
      raise "History poll failed (HTTP #{resp.code})" unless resp.code == '200'

      history = JSON.parse(resp.body)
      result = history[prompt_id]
      if result
        outputs = extract_output_filenames(result)
        return outputs unless outputs.empty?

        # If ComfyUI marks the run complete but outputs are empty, it used a fully
        # cached execution (execution_cached for all nodes) and wrote no new files.
        # Raise immediately rather than spinning until timeout.
        status = result.dig('status', 'status_str')
        completed = result.dig('status', 'completed')
        raise "ComfyUI returned empty outputs (cached execution?) for #{prompt_id}" \
          if completed && status == 'success'

        # ComfyUI may record the prompt before writing output nodes; keep polling.
      end

      sleep POLL_INTERVAL_SEC
    end
  end

  # Download an output image; saves to dest_path.
  def download_output(filename, dest_path)
    resp = get("/view?filename=#{URI.encode_www_form_component(filename)}&type=output&subfolder=")
    raise "Download failed (HTTP #{resp.code}) for #{filename}" unless resp.code == '200'

    FileUtils.mkdir_p(File.dirname(dest_path))
    File.binwrite(dest_path, resp.body)
  end

  # Quick connectivity check; raises on failure.
  def check_connectivity!
    resp = get('/system_stats')
    raise "ComfyUI health check failed (HTTP #{resp.code}): #{resp.body}" unless resp.code == '200'
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
    raise "Cannot reach ComfyUI at #{@host}:#{@port} — is WireGuard (wg1) active? (#{e.message})"
  end

  private

  def extract_output_filenames(result)
    Array(result.dig('outputs'))
      .flat_map { |_node_id, node_out| Array(node_out['images']) }
      .map { |img| img['filename'] }
      .compact
      .reject(&:empty?)
  end

  def get(path)
    uri = URI("http://#{@host}:#{@port}#{path}")
    Net::HTTP.get_response(uri)
  end

  def post_json(path, payload)
    uri = URI("http://#{@host}:#{@port}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(payload)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def post_raw(path, body, content_type)
    uri = URI("http://#{@host}:#{@port}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = content_type
    req.body = body
    Net::HTTP.start(uri.host, uri.port, read_timeout: 120) { |http| http.request(req) }
  end

  def mime_type_for(file_path)
    case File.extname(file_path).downcase
    when '.jpg', '.jpeg' then 'image/jpeg'
    when '.png'          then 'image/png'
    when '.webp'         then 'image/webp'
    else 'application/octet-stream'
    end
  end

  # Minimal hex token without SecureRandom (pure stdlib).
  def SecureRandom_hex(n)
    Digest::SHA256.hexdigest(Time.now.to_f.to_s + rand.to_s)[0, n * 2]
  end
end

# ---------------------------------------------------------------------------
# Manifest — tracks which files have been processed to avoid re-enhancing.
# ---------------------------------------------------------------------------

class ProcessedManifest
  MANIFEST_FILE = '.photo-enhance-processed'

  def initialize(outdir)
    @path = File.join(outdir, MANIFEST_FILE)
    @entries = load_entries
  end

  def processed?(file_path)
    key = digest(file_path)
    @entries.include?(key)
  end

  def mark_done(file_path)
    key = digest(file_path)
    @entries << key
    File.open(@path, 'a') { |f| f.puts(key) }
  end

  private

  def load_entries
    return [] unless File.exist?(@path)

    File.readlines(@path, chomp: true).map(&:strip).reject(&:empty?).to_set
  end

  # Digest includes mtime so a re-shot of the same filename is re-processed.
  def digest(file_path)
    stat = File.stat(file_path)
    Digest::SHA256.hexdigest("#{File.basename(file_path)}:#{stat.size}:#{stat.mtime.to_i}")
  rescue Errno::ENOENT
    Digest::SHA256.hexdigest(File.basename(file_path))
  end
end

# ---------------------------------------------------------------------------
# Enhancer — orchestrates upload → prompt → poll → download for one image.
# ---------------------------------------------------------------------------

class PhotoEnhancer
  SUPPORTED_EXTENSIONS = %w[.jpg .jpeg .png .webp].freeze

  def initialize(config:, client:, workflow:, indir:, manifest:, out: $stdout)
    @config   = config
    @client   = client
    @workflow = workflow
    @indir    = indir
    @manifest = manifest
    @out      = out
  end

  def enhance_directory(indir, watch: false)
    @client.check_connectivity!
    @out.puts "ComfyUI ready at http://#{@config.host}:#{@config.port}"
    @out.puts "Enhancing photos in #{indir} (output: <name>_e.<ext> alongside originals)"
    @out.puts watch ? '(watch mode — Ctrl-C to stop)' : ''

    loop do
      pending = find_pending_images(indir)
      pending.each { |path| enhance_one(path) }
      break unless watch

      sleep 5
    end
  end

  private

  def find_pending_images(indir)
    Dir.glob(File.join(indir, '*'))
       .select { |f| File.file?(f) && SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase) }
       .reject { |f| File.basename(f, '.*').end_with?('_e') }
       .reject { |f| @manifest.processed?(f) }
       .sort
  end

  def enhance_one(src_path)
    basename   = File.basename(src_path, '.*')
    ext        = File.extname(src_path).downcase
    # Output lives in the same directory as the original, with an _enhanced suffix
    # before the extension (e.g. photo.jpg -> photo_enhanced.jpg).
    dest_path  = File.join(File.dirname(src_path), "#{basename}_e#{ext}")

    @out.puts "[#{Time.now.strftime('%H:%M:%S')}] Enhancing #{File.basename(src_path)}..."

    # Auto-rotate based on EXIF orientation before uploading. ComfyUI strips EXIF,
    # so we bake the rotation into a temp file; this ensures output is correctly oriented.
    upload_path = auto_orient_tempfile(src_path)
    uploaded_name = @client.upload_image(upload_path)
    workflow      = inject_input_image(@workflow, uploaded_name)
    prompt_id     = @client.submit_prompt(workflow)
    @out.puts "  Submitted prompt #{prompt_id}, waiting for ComfyUI..."

    filenames = @client.wait_for_output(prompt_id)
    raise "No output images returned for #{src_path}" if filenames.empty?

    # ComfyUI SaveImage always outputs PNG. Download to a temp file then convert
    # to the original format (JPEG for .jpg/.jpeg) so file sizes stay comparable.
    tmp_path = "#{dest_path}.tmp.png"
    @client.download_output(filenames.first, tmp_path)
    convert_to_original_format(tmp_path, dest_path, ext)
    File.delete(tmp_path) if File.exist?(tmp_path)
    File.delete(upload_path) if upload_path != src_path && File.exist?(upload_path)
    @manifest.mark_done(src_path)
    orig_size    = File.size(src_path)
    enhanced_size = File.size(dest_path)
    @out.puts "  Saved -> #{dest_path} (#{kb(orig_size)} KB -> #{kb(enhanced_size)} KB)"
  rescue StandardError => e
    @out.puts "  ERROR enhancing #{File.basename(src_path)}: #{e.message}"
  end

  # Apply EXIF auto-orientation to a copy of src_path and return the copy's path.
  # If magick fails (e.g. not installed or no EXIF), returns src_path unchanged so
  # the caller always has a valid upload path.
  def auto_orient_tempfile(src_path)
    ext    = File.extname(src_path)
    tmp    = "#{src_path}.orient#{ext}"
    success = system('magick', src_path, '-auto-orient', tmp)
    return tmp if success && File.exist?(tmp)

    @out.puts "  Warning: auto-orient failed for #{File.basename(src_path)}, uploading original"
    src_path
  end

  # Convert the PNG downloaded from ComfyUI into the desired output format and
  # apply local colour corrections via ImageMagick:
  #   -sigmoidal-contrast 3,50%   — gentle S-curve (lifts shadows, adds punch)
  #   -modulate 100,120,100       — +20% saturation (vibrance-style boost)
  #   -unsharp 0x1.5+0.7+0.02    — mild clarity / micro-contrast sharpening
  # PNG output gets the same corrections but stays lossless.
  def convert_to_original_format(src_png, dest_path, original_ext)
    color_args = [
      '-sigmoidal-contrast', '3,50%',
      '-modulate',           '100,120,100',
      '-unsharp',            '0x1.5+0.7+0.02'
    ]
    case original_ext
    when '.jpg', '.jpeg'
      system('magick', src_png, *color_args, '-quality', '92', dest_path)
    else
      system('magick', src_png, *color_args, dest_path)
    end
  end

  def kb(bytes)
    (bytes / 1024.0).round
  end

  # Inject the input filename and a unique SaveImage prefix into the workflow.
  # The unique prefix prevents ComfyUI from returning a fully-cached execution
  # (outputs: {}) instead of actually running the pipeline and writing output files.
  def inject_input_image(workflow, filename)
    modified = JSON.parse(JSON.generate(workflow)) # deep dup
    unique_prefix = "enhanced_#{Digest::SHA256.hexdigest(Time.now.to_f.to_s + rand.to_s)[0, 8]}_"
    modified.each_value do |node|
      next unless node.is_a?(Hash)

      case node['class_type']
      when 'LoadImage'
        node['inputs']['image'] = filename
      when 'SaveImage'
        node['inputs']['filename_prefix'] = unique_prefix
      end
    end
    modified
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
  o.on('--config PATH',   'TOML config file (default: hyperstack-vm-photo.toml)') { |v| options[:config] = v }
  o.on('--indir PATH',    'Directory of photos to enhance (output: <name>_enhanced.<ext> in same dir)') { |v| options[:indir] = v }
  o.on('--workflow PATH', 'ComfyUI workflow JSON (default: workflows/photo-enhance.json)') { |v| options[:workflow] = v }
  o.on('--watch',         'Keep running and process new images as they arrive')    { options[:watch] = true }
  o.on('--test',          'Only check connectivity to ComfyUI, then exit')         { options[:test] = true }
  o.on('-h', '--help',    'Show this help') { puts o; exit }
end.parse!

unless File.exist?(options[:config])
  warn "Config not found: #{options[:config]}"
  exit 1
end

cfg    = PhotoConfig.new(options[:config], options[:workflow])
client = ComfyUIClient.new(host: cfg.host, port: cfg.port)

if options[:test]
  begin
    client.check_connectivity!
    puts "ComfyUI is reachable at http://#{cfg.host}:#{cfg.port} — OK"
    exit 0
  rescue RuntimeError => e
    warn "ERROR: #{e.message}"
    exit 1
  end
end

unless options[:indir]
  warn '--indir is required (use --test to only check connectivity)'
  exit 1
end

indir = File.expand_path(options[:indir])

unless File.directory?(indir)
  warn "Input directory not found: #{indir}"
  exit 1
end

unless File.exist?(cfg.workflow_path)
  warn "Workflow JSON not found: #{cfg.workflow_path}"
  warn "Expected at #{File.join(__dir__, 'workflows', 'photo-enhance.json')}"
  exit 1
end

workflow = JSON.parse(File.read(cfg.workflow_path))
# Manifest lives in the indir so it stays with the photos.
manifest = ProcessedManifest.new(indir)
enhancer = PhotoEnhancer.new(config: cfg, client: client, workflow: workflow,
                              indir: indir, manifest: manifest)
begin
  enhancer.enhance_directory(indir, watch: options[:watch])
rescue RuntimeError => e
  warn "ERROR: #{e.message}"
  exit 1
rescue Interrupt
  puts "\nStopped."
end
