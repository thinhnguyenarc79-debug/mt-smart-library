# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

class TestHotReload < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('hot_')
    @plugins = File.join(@tmp, 'Plugins')
    @data = File.join(@tmp, 'Data')
    FileUtils.mkdir_p([@plugins, @data])
    FileUtils.cp(File.join(SRC, 'mt_smart_library.rb'), @plugins)
    FileUtils.cp_r(File.join(SRC, 'mt_smart_library'), @plugins)
    @log = SL::Logger.new(File.join(@data, 'logs', 't.log'))
    @u = SL::Updater.new(logger: @log, http: nil, plugins_root: @plugins, data_root: @data)
  end

  def pkg(&mod)
    st = Dir.mktmpdir('pk_')
    FileUtils.cp(File.join(@plugins, 'mt_smart_library.rb'), st)
    FileUtils.cp_r(File.join(@plugins, 'mt_smart_library'), st)
    code = File.join(st, 'mt_smart_library')
    vf = File.join(code, 'updater', 'version.rb')
    File.write(vf, File.read(vf).sub(/VERSION = '[^']+'/, "VERSION = '9.0.1'"))
    mf = File.join(code, 'updater', 'update_manifest.json')
    File.write(mf, JSON.generate(JSON.parse(File.read(mf)).merge('version' => '9.0.1')))
    mod&.call(code, st)
    out = File.join(Dir.mktmpdir, 'p.rbz')
    _o, s = Open3.capture2e('zip', '-r', '-X', '-q', out, '.', chdir: st)
    raise 'zip' unless s.success?
    out
  end

  def test_classify_hot_and_system
    hot = @u.inspect_package(pkg { |c, _| File.write(File.join(c, 'ui', 'app.css'), "/* x */\n", mode: 'a'); File.write(File.join(c, 'ai_runtime', 'source_extractor.py'), "# x\n", mode: 'a') })
    assert_equal 'hot', hot['update']['type'], hot['update'].inspect
    assert_includes hot['update']['changed'], 'mt_smart_library/ui/app.css'
    assert_includes hot['update']['changed'], 'mt_smart_library/updater/version.rb'
    assert_match(/không cần khởi động lại/, hot['update']['reason'])
    sys = @u.inspect_package(pkg { |c, _| File.write(File.join(c, 'ui', 'app.rb'), "\n# x\n", mode: 'a') })
    assert_equal 'system', sys['update']['type']
    assert_equal ['mt_smart_library/ui/app.rb'], sys['update']['system_files']
    loader = @u.inspect_package(pkg { |_c, st| File.write(File.join(st, 'mt_smart_library.rb'), "\n# x\n", mode: 'a') })
    assert_equal 'system', loader['update']['type'], 'loader đổi → hệ thống'
    gone = @u.inspect_package(pkg { |c, _| File.delete(File.join(c, 'sources', 'link_import.rb')) })
    assert_equal 'system', gone['update']['type'], 'xóa file Ruby → hệ thống'
    hr = @u.inspect_package(pkg { |c, _| File.write(File.join(c, 'sources', 'link_import.rb'), "\n# x\n", mode: 'a') })
    assert_equal 'hot', hr['update']['type'], 'module thuần hàm được khai báo nạp lại'
  end

  def test_hot_install_no_restart_and_system_install_pending
    info = @u.inspect_package(pkg { |c, _| File.write(File.join(c, 'ui', 'app.css'), "/* x */\n", mode: 'a') })
    @u.start_install(info, 'Cập nhật từ file')
    @u.thread.join
    ev = @u.events
    done = ev.find { |t, _| t == :install_done }[1]
    assert done['hot']
    assert_includes done['changed'], 'mt_smart_library/ui/app.css'
    assert_nil @u.pending_restart_version, 'cập nhật nhanh: không chờ khởi động lại'
    assert_match(/9\.0\.1/, File.read(File.join(@plugins, 'mt_smart_library', 'updater', 'version.rb')))
    assert_equal 1, @u.backups.list.size, 'vẫn sao lưu trước khi cài'
    info2 = @u.inspect_package(pkg { |c, _| File.write(File.join(c, 'main.rb'), "\n# x\n", mode: 'a') })
    @u.start_install(info2, 'Cập nhật từ file')
    @u.thread.join
    d2 = @u.events.find { |t, _| t == :install_done }[1]
    refute d2['hot']
    assert_equal '9.0.1', @u.pending_restart_version, 'bản hệ thống: chờ người dùng khởi động lại'
  end

  def test_reload_ruby_modules_in_place
    code = File.join(@plugins, 'mt_smart_library')
    li = File.join(code, 'sources', 'link_import.rb')
    File.write(li, File.read(li).sub('module_function', "module_function\n\n      def hot_marker\n        42\n      end"))
    vf = File.join(code, 'updater', 'version.rb')
    old = SL::VERSION
    File.write(vf, File.read(vf).sub(/VERSION = '[^']+'/, "VERSION = '9.9.9'"))
    done = SL::HotReload.reload_ruby(%w[mt_smart_library/sources/link_import.rb mt_smart_library/updater/version.rb mt_smart_library/ui/app.rb], code)
    assert_equal %w[sources/link_import.rb updater/version.rb], done, 'chỉ nạp lại module được khai báo'
    assert_equal 42, SL::LinkImport.hot_marker
    assert_equal :download, SL::LinkImport.classify('https://x.example.com/a.zip')[:kind], 'chức năng cũ vẫn chạy'
    assert_equal '9.9.9', SL::VERSION
    assert_equal 'mtdesign.smart_library_pro', SL::PLUGIN_ID
  ensure
    orig = File.join(SRC, 'mt_smart_library')
    SL::HotReload.reload_ruby(%w[mt_smart_library/sources/link_import.rb mt_smart_library/updater/version.rb], orig)
    assert_equal old, SL::VERSION if old
  end

  def test_app_hot_apply_reloads_ui_and_python_without_duplicates
    SL::Paths.reset!
    ENV['MT_SMART_LIBRARY_DATA'] = @data
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    UI::HtmlDialog.instances.clear
    app = SL::App.new
    app.show
    d = UI::HtmlDialog.instances.last
    d.fire('ready')
    cbs = d.callbacks.keys.size if d.respond_to?(:callbacks)
    timers = UI.timers.size
    restarted = []
    rt = app.instance_variable_get(:@runtime)
    rt.lanes.each { |l| l.define_singleton_method(:restart_when_idle) { restarted << name } }
    ok = app.hot_apply('version' => '9.0.1', 'changed' => %w[mt_smart_library/ui/app.js mt_smart_library/ai_runtime/inference_worker.py])
    assert ok
    assert_equal %w[search index crawl].sort, restarted.sort, 'tiến trình Python khởi động lại khi rảnh'
    assert_equal 1, UI::HtmlDialog.instances.size, 'không tạo dialog mới'
    assert_match(%r{ui/index\.html\z}, d.file)
    assert_equal timers, UI.timers.size, 'không thêm timer'
    assert_equal cbs, d.callbacks.keys.size if cbs
  ensure
    SL::Paths.reset!
  end
end
