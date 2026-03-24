#!/usr/bin/env ruby
# frozen_string_literal: true

# photo-compare.rb — Side-by-side before/after photo comparison and selection tool.
#
# Shows each original + enhanced pair side by side, filling the window.
# Press O to move the original to --outdir, E to move the enhanced version,
# Space/S to skip. Rescans after each action so newly finished photos appear.
#
# Usage:
#   ruby photo-compare.rb --indir ~/Downloads/fuji --outdir ~/Downloads/fuji/selected
#
# Keyboard shortcuts:
#   O        — move original to outdir
#   E        — move enhanced to outdir
#   Space/S  — skip (leave both, advance to next)
#   Q/Escape — quit

require 'gtk4'
require 'optparse'
require 'fileutils'

SUPPORTED_EXTENSIONS = %w[.jpg .jpeg .png .webp].freeze

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def find_pairs(indir)
  Dir.glob(File.join(indir, '*'))
     .select { |f| File.file?(f) && SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase) }
     .reject { |f| File.basename(f, '.*').end_with?('_e') }
     .reject { |f| File.basename(f).include?('.orient.') }
     .filter_map do |orig|
       ext  = File.extname(orig).downcase  # enhanced files always have lowercase ext
       base = File.basename(orig, File.extname(orig))
       enh  = File.join(File.dirname(orig), "#{base}_e#{ext}")
       [orig, enh] if File.exist?(enh)
     end
     .sort
end

def kb(path)
  (File.size(path) / 1024.0).round
end

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

options = { indir: nil, outdir: nil }
OptionParser.new do |o|
  o.banner = 'Usage: ruby photo-compare.rb --indir DIR --outdir DIR'
  o.on('--indir PATH',  'Directory with original + _e photo pairs') { |v| options[:indir]  = v }
  o.on('--outdir PATH', 'Directory to move selected photos into')   { |v| options[:outdir] = v }
  o.on('-h', '--help', 'Show this help') { puts o; exit }
end.parse!

abort '--indir is required'  unless options[:indir]
abort '--outdir is required' unless options[:outdir]

indir  = File.expand_path(options[:indir])
outdir = File.expand_path(options[:outdir])
FileUtils.mkdir_p(outdir)

state = { pairs: find_pairs(indir), index: 0, indir: indir, outdir: outdir }
abort "No before/after pairs found in #{indir}" if state[:pairs].empty?

# ---------------------------------------------------------------------------
# GTK4 UI
# ---------------------------------------------------------------------------

app = Gtk::Application.new('org.hypr.photo-compare', :default_flags)

app.signal_connect('activate') do |a|
  win = Gtk::ApplicationWindow.new(a)
  win.title = 'Photo Compare'
  win.maximize  # fill the screen

  root = Gtk::Box.new(:vertical, 4)
  root.margin_top = root.margin_bottom = root.margin_start = root.margin_end = 6
  win.child = root

  # Top: progress info
  progress_lbl = Gtk::Label.new
  progress_lbl.xalign = 0
  root.append(progress_lbl)

  # Middle: two pictures side by side — Gtk::Picture scales to fill its container
  img_row      = Gtk::Box.new(:horizontal, 8)
  img_row.vexpand = true
  root.append(img_row)

  left_frame  = Gtk::Box.new(:vertical, 2)
  right_frame = Gtk::Box.new(:vertical, 2)
  left_frame.hexpand = right_frame.hexpand = true
  left_frame.vexpand = right_frame.vexpand = true

  # Gtk::Picture is GTK4's scaling image widget; content_fit: :contain keeps aspect ratio
  left_pic  = Gtk::Picture.new
  right_pic = Gtk::Picture.new
  left_pic.content_fit  = :contain
  right_pic.content_fit = :contain
  left_pic.hexpand  = left_pic.vexpand  = true
  right_pic.hexpand = right_pic.vexpand = true

  left_lbl  = Gtk::Label.new
  right_lbl = Gtk::Label.new

  left_frame.append(left_pic)
  left_frame.append(left_lbl)
  right_frame.append(right_pic)
  right_frame.append(right_lbl)
  img_row.append(left_frame)
  img_row.append(right_frame)

  # Bottom: action buttons
  btn_row  = Gtk::Box.new(:horizontal, 16)
  btn_row.halign = :center
  orig_btn = Gtk::Button.new(label: '← Original  [O]')
  skip_btn = Gtk::Button.new(label: 'Skip  [Space]')
  enh_btn  = Gtk::Button.new(label: 'Enhanced →  [E]')
  btn_row.append(orig_btn)
  btn_row.append(skip_btn)
  btn_row.append(enh_btn)
  root.append(btn_row)

  # -----------------------------------------------------------------------
  # Refresh display for current pair
  # -----------------------------------------------------------------------
  refresh = lambda do
    orig, enh = state[:pairs][state[:index]]
    progress_lbl.label = "#{state[:index] + 1} / #{state[:pairs].length}  —  #{File.basename(orig)}"
    left_pic.set_filename(orig)
    right_pic.set_filename(enh)
    left_lbl.label  = "Original (#{kb(orig)} KB)"
    right_lbl.label = "Enhanced (#{kb(enh)} KB)"
  end

  # -----------------------------------------------------------------------
  # After moving (or skipping), rescan and show next pair.
  # Moving removes the pair from the list, so index stays put and naturally
  # points at the next pair. Skip increments the index explicitly.
  # -----------------------------------------------------------------------
  advance = lambda do |pick|
    unless pick.nil?
      FileUtils.mv(pick, File.join(state[:outdir], File.basename(pick)))
    else
      state[:index] += 1
    end

    state[:pairs] = find_pairs(state[:indir])

    if state[:index] >= state[:pairs].length
      progress_lbl.label = 'All pairs reviewed — you can close the window.'
      left_pic.set_filename(nil)
      right_pic.set_filename(nil)
      left_lbl.label = right_lbl.label = ''
      [orig_btn, skip_btn, enh_btn].each { |b| b.sensitive = false }
    else
      refresh.call
    end
  end

  orig_btn.signal_connect('clicked') { advance.call(state[:pairs][state[:index]][0]) }
  enh_btn.signal_connect('clicked')  { advance.call(state[:pairs][state[:index]][1]) }
  skip_btn.signal_connect('clicked') { advance.call(nil) }

  key_ctrl = Gtk::EventControllerKey.new
  key_ctrl.signal_connect('key-pressed') do |_ctrl, keyval, _code, _mod|
    case keyval
    when Gdk::Keyval::KEY_o, Gdk::Keyval::KEY_O      then orig_btn.emit('clicked')
    when Gdk::Keyval::KEY_e, Gdk::Keyval::KEY_E      then enh_btn.emit('clicked')
    when Gdk::Keyval::KEY_s, Gdk::Keyval::KEY_S,
         Gdk::Keyval::KEY_space                      then skip_btn.emit('clicked')
    when Gdk::Keyval::KEY_q, Gdk::Keyval::KEY_Escape then a.quit
    end
    false
  end
  win.add_controller(key_ctrl)

  refresh.call
  win.show
end

exit app.run([])
