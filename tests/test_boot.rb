# frozen_string_literal: true
# Mô phỏng SketchUp nạp extension từ chính file RBZ đã build: menu/toolbar/extension không bị trùng.
Encoding.default_external = Encoding::UTF_8
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'set'

$loaded_files = Set.new
$registered = []
$menu_items = []
$toolbars = []
def file_loaded?(f); $loaded_files.include?(f); end
def file_loaded(f); $loaded_files << f; end
$LOADED_FEATURES << 'sketchup.rb' << 'extensions.rb'
class SketchupExtension
  attr_accessor :version, :creator, :copyright, :description
  attr_reader :name, :path
  def initialize(name, path); @name = name; @path = path; end
end
TB_NEVER_SHOWN = -1
module Sketchup
  def self.version; '22.0.354'; end
  def self.register_extension(ext, load)
    $registered << ext
    require File.join($plugins, ext.path) if load
  end
end
module UI
  class Command
    attr_accessor :tooltip, :status_bar_text, :small_icon, :large_icon
    def initialize(name, &b); @name = name; @b = b; end
  end
  class Menu
    def add_submenu(n); $menu_items << [:submenu, n]; self; end
    def add_item(c, &b); $menu_items << [:item, c]; end
    def add_separator; end
  end
  class Toolbar
    attr_reader :items
    def initialize(n); @items = []; $toolbars << self; end
    def add_item(c); @items << c; end
    def get_last_state; TB_NEVER_SHOWN; end
    def show; @shown = true; end
    def restore; end
  end
  def self.menu(_n); Menu.new; end
  def self.start_timer(*); 1; end
end

class TestBoot < Minitest::Test
  def test_boot_from_built_rbz_twice
    rbz = Dir.glob(File.expand_path('../dist/*.rbz', __dir__)).max_by { |f| File.mtime(f) }
    skip 'chưa build RBZ' unless rbz
    $plugins = Dir.mktmpdir('Plugins_')
    data = Dir.mktmpdir('data_')
    ENV['MT_SMART_LIBRARY_DATA'] = data
    _o, st = Open3.capture2e('unzip', '-q', rbz, '-d', $plugins)
    assert st.success?
    loader = File.join($plugins, 'mt_smart_library.rb')
    require loader
    load loader # nạp lại (ví dụ người dùng cài đè khi SketchUp đang mở)
    load File.join($plugins, 'mt_smart_library', 'main.rb')
    assert_equal 1, $registered.size, 'chỉ đăng ký 1 extension'
    assert_equal File.read(File.join($plugins, 'mt_smart_library', 'updater', 'version.rb'))[/VERSION = '([^']+)'/, 1], $registered[0].version
    assert_equal 1, $toolbars.size, 'chỉ 1 toolbar'
    assert_equal 2, $toolbars[0].items.size
    assert_equal 1, $menu_items.count { |t, _| t == :submenu }, 'không trùng menu'
    icons = $toolbars[0].items.flat_map { |c| [c.small_icon, c.large_icon] }
    assert(icons.all? { |i| File.file?(i) }, 'icon toolbar tồn tại')
    assert File.directory?(data), 'thư mục dữ liệu người dùng tách riêng'
    refute Dir.glob(File.join($plugins, 'mt_smart_library', '**', 'settings.json')).any?, 'không ghi dữ liệu vào thư mục plugin'
  end
end
