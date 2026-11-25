# frozen_string_literal: true
# Môi trường kiểm thử ngoài SketchUp: stub tối thiểu Sketchup/UI để nạp mã nguồn thật.
Encoding.default_external = Encoding::UTF_8 # giống môi trường SketchUp
Encoding.default_internal = nil
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'socket'

SRC = File.expand_path('../src', __dir__)
TEST_DATA = Dir.mktmpdir('mtsl_data_')
ENV['MT_SMART_LIBRARY_DATA'] = TEST_DATA
ENV.delete('OPENAI_API_KEY')
ENV.delete('SKETCHFAB_API_TOKEN')

# ---------------- Stub SketchUp API (ghi lại lời gọi để kiểm tra lifecycle) ----------------
module Sketchup
  @calls = []
  @thumb_ok = true
  class << self
    attr_accessor :calls, :thumb_ok, :model
    def version; '22.0.354'; end
    def save_thumbnail(skp, png)
      @calls << [:save_thumbnail, skp]
      return false unless @thumb_ok && File.file?(skp)
      File.binwrite(png, "\x89PNG\r\n\x1a\nFAKE".b)
      true
    end
    def active_model; @model; end
    def status_text=(t); @calls << [:status_text, t]; end
  end
end

module UI
  @timers = {}
  @seq = 0
  @opened = []
  @panel = nil
  @dir = nil
  class << self
    attr_accessor :timers, :opened, :panel, :dir
    def start_timer(sec, repeat = false, &blk)
      @seq += 1
      @timers[@seq] = { sec: sec, repeat: repeat, blk: blk }
      @seq
    end
    def stop_timer(id); @timers.delete(id); end
    def openURL(u); @opened << u; true; end
    def openpanel(*); @panel; end
    def select_directory(*); @dir; end
    def messagebox(*); 6; end
    # Chạy các timer 1 lần (mô phỏng vòng sự kiện SketchUp).
    def run_timers(times = 1)
      times.times do
        @timers.dup.each do |id, t|
          next unless @timers.key?(id)
          @timers.delete(id) unless t[:repeat]
          t[:blk].call
        end
      end
    end
  end

  class HtmlDialog
    STYLE_DIALOG = 1
    @instances = []
    class << self; attr_accessor :instances; end
    attr_reader :callbacks, :scripts, :file, :opts, :shown
    def initialize(opts)
      @opts = opts; @callbacks = {}; @scripts = []; @visible = false; @shown = 0
      self.class.instances << self
    end
    def set_file(f); @file = f; end
    def add_action_callback(name, &blk)
      raise "Callback trùng: #{name}" if @callbacks.key?(name)
      @callbacks[name] = blk
    end
    def set_on_closed(&blk); @on_closed = blk; end
    def show; @visible = true; @shown += 1; end
    def visible?; @visible; end
    def bring_to_front; @front = true; end
    def execute_script(js); @scripts << js; end
    def close; @visible = false; @on_closed&.call; end
    def fire(name, *args); @callbacks.fetch(name).call(nil, *args); end
    def messages(type = nil)
      @scripts.map do |s|
        m = s.match(/\Awindow\.(?:MT|UP)&&(?:MT|UP)\.receive\((".*?"),(.*)\)\z/m)
        next unless m
        [JSON.parse(m[1]), JSON.parse(m[2])]
      end.compact.select { |t, _| type.nil? || t == type }
    end
  end
end
MB_YESNO = 4
IDYES = 6
def file_loaded?(_f); false; end
def file_loaded(_f); end

module MTDesign
  module SmartLibrary
    CODE_DIR = File.join(SRC, 'mt_smart_library') unless const_defined?(:CODE_DIR)
  end
end
%w[
  updater/version core/util core/paths core/logger core/settings core/synonyms core/search_index core/indexer
  core/thumbs core/inserter core/secret_store net/http_client online/link_sources online/sketchfab online/polyhaven online/wp_sources sources/source_registry sources/site_probe sources/link_import accounts/account_manager core/download_watcher ai/vision
  search/query_normalizer search/categories search/result_cache search/result_ranker
  search/providers/base_provider search/providers/local_provider search/providers/sketchfab_provider search/providers/polyhaven_provider search/providers/wp_provider search/search_manager
  importers/gltf_importer convert/blender_runner convert/blender_detector convert/model_cache convert/converter_manager convert/import_manager ai_runtime/worker_lane ai_runtime/runtime_manager visual_search/visual_search_manager
  updater/zip_reader updater/backup_manager updater/updater ui/app
].each { |f| require File.join(SRC, 'mt_smart_library', f) }
MTDesign::SmartLibrary::Paths.code_dir = File.join(SRC, 'mt_smart_library')
SL = MTDesign::SmartLibrary

# ---------------- Máy chủ HTTP giả lập (không tốn phí, không ra Internet) ----------------
class MockHTTP
  attr_reader :port, :requests
  def initialize(&handler)
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @handler = handler
    @requests = []
    @thread = Thread.new { loop { client = @server.accept; Thread.new(client) { |c| serve(c) } } }
  end
  def url(path = '/'); "http://127.0.0.1:#{@port}#{path}"; end
  def serve(c)
    line = c.gets.to_s
    meth, path = line.split(' ')
    headers = {}
    while (l = c.gets) && l != "\r\n"
      k, v = l.split(':', 2)
      headers[k.downcase.strip] = v.to_s.strip
    end
    body = headers['content-length'] ? c.read(headers['content-length'].to_i) : nil
    req = { method: meth, path: path, headers: headers, body: body }
    @requests << req
    code, hdrs, resp = @handler.call(req)
    return if code == :hang
    hdrs = { 'Content-Type' => 'application/json' }.merge(hdrs || {})
    resp = resp.to_s.b
    c.write("HTTP/1.1 #{code} X\r\n")
    hdrs.each { |k, v| c.write("#{k}: #{v}\r\n") }
    c.write("Content-Length: #{resp.bytesize}\r\nConnection: close\r\n\r\n")
    c.write(resp)
  rescue StandardError
    nil
  ensure
    c.close rescue nil
  end
  def close; @thread.kill; @server.close rescue nil; end
end

# Chờ callback HTTP (poll ở "main thread").
def wait_http(client, timeout = 10)
  t0 = Time.now
  until yield
    client.poll
    raise 'timeout chờ HTTP' if Time.now - t0 > timeout
    sleep 0.02
  end
end

def wait_until(timeout = 10)
  t0 = Time.now
  until yield
    raise 'timeout' if Time.now - t0 > timeout
    sleep 0.02
  end
end
