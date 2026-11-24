# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

class FakeDefs
  attr_reader :loaded
  def initialize; @loaded = []; end
  def load(path, allow_newer: false)
    raise RuntimeError, 'This file was created by a newer version' if path.include?('NEWER') && !allow_newer
    @loaded << [path, allow_newer]
    :definition
  end
end

class FakeModel
  attr_reader :definitions, :placed, :ops
  def initialize; @definitions = FakeDefs.new; @placed = []; @ops = []; end
  def start_operation(*a); @ops << [:start, *a]; end
  def commit_operation; @ops << [:commit]; end
  def abort_operation; @ops << [:abort]; end
  def place_component(d, r); @placed << [d, r]; end
  def modified?; true; end
end

class TestApp < Minitest::Test
  KEY = 'sk-test-SECRETKEY-1234567890abcdef'

  def setup
    SL::Paths.reset!
    @data = Dir.mktmpdir('appdata_')
    ENV['MT_SMART_LIBRARY_DATA'] = @data
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    UI::HtmlDialog.instances.clear
    UI.timers.clear
    UI.opened.clear
    Sketchup.model = FakeModel.new
    @app = SL::App.new
    @lib = Dir.mktmpdir('lib_')
    FileUtils.mkdir_p(File.join(@lib, 'Ghế'))
    File.write(File.join(@lib, 'Ghế', 'Ghế sofa vải.skp'), 'x')
    File.write(File.join(@lib, 'Bàn ăn gỗ.skp'), 'y')
    File.write(File.join(@lib, 'NEWER chair.skp'), 'z')
  end

  def teardown
    SL::Paths.reset!
  end

  def dlg
    UI::HtmlDialog.instances.last
  end

  def pump(max = 400)
    max.times do
      UI.run_timers
      return if yield
      sleep 0.01
    end
    flunk 'pump timeout'
  end

  def test_dialog_lifecycle_and_timer
    @app.show
    assert_equal 1, UI::HtmlDialog.instances.size
    d = dlg
    assert_match(/ui\/index\.html\z/, d.file)
    assert d.messages.empty?, 'không gửi dữ liệu trước khi giao diện báo ready'
    d.fire('ready')
    init = d.messages('init').last[1]
    assert_equal SL::VERSION, init['version']
    @app.show
    assert_equal 1, UI::HtmlDialog.instances.size, 'mở lại khi đang mở chỉ đưa dialog lên trước'
    timer_count = UI.timers.size
    @app.show
    assert_equal timer_count, UI.timers.size, 'không tạo thêm timer'
    pump { @app.instance_variable_get(:@library_loaded) }
    d.close
    pump { @app.instance_variable_get(:@timer).nil? }
    assert_empty UI.timers, 'timer dừng khi đóng dialog và không còn việc nền'
    @app.show
    assert_equal 2, UI::HtmlDialog.instances.size
    dlg.fire('ready') # callback của dialog mới đăng ký đúng 1 lần (stub raise nếu trùng)
  end

  def test_scan_search_insert_history_flow
    UI.dir = @lib
    @app.show
    d = dlg
    d.fire('ready')
    pump { @app.instance_variable_get(:@library_loaded) }
    d.fire('add_root')
    pump { d.messages('scan_done').any? }
    sd = d.messages('scan_done').last[1]
    assert_equal 3, sd['models']
    d.fire('search', JSON.generate('q' => 'ghe', 'tab' => 'offline', 'seq' => 5))
    r = d.messages('results').last[1]
    assert_equal 5, r['seq']
    assert_equal ['Ghế sofa vải', 'NEWER chair'], r['items'].map { |x| x['name'] }, 'khớp tên gốc xếp trước, đồng nghĩa (chair) xếp sau'
    id = r['items'][0]['id']
    d.fire('thumbs', JSON.generate([id]))
    pump { d.messages('thumb').any? }
    assert_match(/\Adata:image\/png/, d.messages('thumb').last[1]['src'])
    d.fire('insert', id)
    pump { Sketchup.model.placed.any? }
    assert_equal [[:start, 'MT Smart Library: nạp model', true], [:commit]], Sketchup.model.ops
    assert_equal id, @app.settings['history'].first
    d.fire('favorite', id)
    assert_equal({ 'id' => id, 'on' => true }, d.messages('fav').last[1])
    d.fire('search', JSON.generate('q' => '', 'tab' => 'favorites', 'seq' => 6))
    assert_equal 1, d.messages('results').last[1]['total']
    # File phiên bản mới hơn -> hỏi xác nhận trong giao diện, không dùng modal trong timer
    d.fire('search', JSON.generate('q' => 'newer', 'tab' => 'offline', 'seq' => 7))
    nid = d.messages('results').last[1]['items'][0]['id']
    d.fire('insert', nid)
    pump { d.messages('confirm_newer').any? }
    d.fire('insert', nid, true)
    pump { Sketchup.model.definitions.loaded.any? { |_, an| an } }
    # Xóa root -> thư viện trống, dữ liệu yêu thích vẫn giữ
    d.fire('remove_root', @lib)
    d.fire('search', JSON.generate('q' => '', 'tab' => 'offline', 'seq' => 9))
    assert_equal 0, d.messages('results').last[1]['total']
    assert_includes @app.settings['favorites'], id
  end

  def test_secret_never_leaks
    @app.show
    d = dlg
    d.fire('ready')
    d.fire('set_secret', JSON.generate('kind' => 'openai', 'value' => KEY, 'remember' => false))
    assert @app.send(:secrets_state)['openai']['session']
    @app.log.error("Thử log key #{KEY}")
    mock = MockHTTP.new do |req|
      if req[:body].to_s.include?('reasoning_effort')
        [400, {}, JSON.generate('error' => { 'message' => "Unsupported parameter: 'reasoning_effort'" })]
      elsif req[:headers]['authorization'] == "Bearer #{KEY}"
        content = JSON.generate('object_type' => 'sofa', 'style' => 'modern', 'material' => 'fabric', 'color' => 'gray',
                                'queries_vi' => ['ghế sofa vải'], 'queries_en' => ['fabric sofa'])
        [200, {}, JSON.generate('choices' => [{ 'message' => { 'content' => content } }])]
      else
        [401, {}, JSON.generate('error' => { 'message' => "Incorrect API key provided: #{KEY}" })]
      end
    end
    @app.settings.data['ai']['base_url'] = mock.url('/v1') # chỉ trong test (cấu hình thật bắt buộc https)
    d.fire('ai_send', JSON.generate('b64' => 'iVBORw0KGgo=', 'mime' => 'image/png'))
    pump { d.messages('ai_result').any? || d.messages('ai_state').any? { |_, p| p['state'] == 'error' } }
    res = d.messages('ai_result').last
    refute_nil res, d.messages('ai_state').inspect
    assert_equal ['ghế sofa vải'], res[1]['queries_vi']
    assert_equal 2, mock.requests.size, 'thử lại 1 lần không có reasoning_effort'
    # Lỗi 401 có chứa key trong thông báo -> phải bị che
    @app.instance_variable_get(:@secrets)['openai'] = KEY + 'X'
    @app.log.add_secret(KEY + 'X')
    d.fire('ai_send', JSON.generate('b64' => 'iVBORw0KGgo=', 'mime' => 'image/png'))
    pump { d.messages('ai_state').any? { |_, p| p['state'] == 'error' } }
    @app.settings.save
    all_js = UI::HtmlDialog.instances.flat_map(&:scripts).join("\n")
    refute_includes all_js, 'SECRETKEY', 'key không xuất hiện trong dữ liệu gửi sang HTML'
    logs = Dir.glob(File.join(@data, 'logs', '*')).map { |f| File.read(f, encoding: 'UTF-8') }.join
    refute_includes logs, 'SECRETKEY', 'key không xuất hiện trong log'
    refute_includes File.read(File.join(@data, 'settings.json')), 'SECRETKEY', 'key không ghi vào settings.json'
    html = File.read(File.join(SRC, 'mt_smart_library', 'ui', 'index.html'))
    refute_match(/https?:\/\/[^"]*\.js/, html, 'không tải JS từ CDN')
  ensure
    mock&.close
  end

  def test_ai_requires_key_and_consent_flow
    @app.show
    d = dlg
    d.fire('ready')
    d.fire('ai_pick')
    assert d.messages('ai_need_key').any?
    @app.instance_variable_get(:@secrets)['openai'] = KEY
    img = File.join(Dir.mktmpdir, 'mẫu.png')
    File.binwrite(img, "\x89PNG\r\n\x1a\n" + 'x' * 100)
    UI.panel = img
    d.fire('ai_pick')
    pv = d.messages('ai_preview').last[1]
    assert_match(/\Adata:image\/png;base64,/, pv['src'])
    assert_equal 'gpt-6-luna', pv['model']
    refute @app.http.busy?, 'chọn ảnh KHÔNG tự gửi lên mạng khi chưa xác nhận'
    UI.panel = nil
  end

  def test_updater_dialog_package_checks
    @app.show_updater
    u = dlg
    assert_match(/update_dialog\.html\z/, u.file)
    u.fire('up_ready')
    init = u.messages('init').last[1]
    assert_equal SL::VERSION, init['version']
    assert_equal 'none', init['source']['source']
    # Gói cùng phiên bản -> yêu cầu xác nhận cài lại, không cài ngay
    pkg = File.join(Dir.mktmpdir, 'same.rbz')
    Open3.capture2e('zip', '-r', '-X', '-q', pkg, 'mt_smart_library.rb', 'mt_smart_library', chdir: SRC)
    UI.panel = pkg
    u.fire('up_pick_file')
    info = u.messages('up_package').last[1]
    assert_equal 'same', info['relation']
    assert info['compatible']
    u.fire('up_install', false)
    assert u.messages('up_confirm_downgrade').any?
    refute @app.updater.busy?
    # Kiểm tra online khi chưa cấu hình nguồn -> báo lỗi rõ ràng, không gọi mạng
    u.fire('up_check_online')
    assert_match(/Chưa cấu hình/, u.messages('up_online_state').last[1]['msg'])
    u.fire('up_save_source', JSON.generate('source' => 'github', 'github_repo' => 'mt-design/mt-smart-library', 'check_on_start' => true))
    assert_equal 'mt-design/mt-smart-library', @app.settings['update']['github_repo']
    UI.panel = nil
  end
end
