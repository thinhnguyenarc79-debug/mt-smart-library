# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

FAKE_BLENDER = File.join(__dir__, 'fixtures', 'fake_blender', 'blender')

class TestBlenderDetector < Minitest::Test
  BD = SL::BlenderDetector
  def test_versions_and_order
    assert_equal [4, 5], BD.guess_version('C:/Program Files/Blender Foundation/Blender 4.5/blender.exe')
    assert BD.supported_version?([4, 5])
    assert BD.supported_version?([3, 6])
    refute BD.supported_version?([5, 0]), 'Blender 5.x đã bỏ COLLADA'
    refute BD.supported_version?([2, 79])
    paths = ['X:/Blender Foundation/Blender 5.0/blender.exe', 'X:/Blender Foundation/Blender 3.6/blender.exe',
             'X:/Blender Foundation/Blender 4.5/blender.exe', 'X:/Blender Foundation/Blender 4.2/blender.exe']
    assert_equal %w[4.5 4.2 3.6 5.0], BD.sort(paths).map { |p| p[/Blender (\d\.\d)\//, 1] }
  end

  def test_probe_args_are_a_list_and_escape_paths
    args = BD.probe_args('C:/B/blender.exe', "C:/Users/Thịnh/x\"y.json")
    assert_equal '--background', args[1]
    assert_includes args, '--factory-startup'
    assert_includes args, '--disable-autoexec'
    assert_includes args.last, '"C:/Users/Thịnh/x\\"y.json"', 'đường dẫn được trích dẫn an toàn trong mã Python'
  end
end

class TestRunnerAndQuote < Minitest::Test
  def test_win_quote_rules
    q = SL::WinProc
    assert_equal 'abc', q.quote('abc')
    assert_equal '""', q.quote('')
    assert_equal '"a b"', q.quote('a b')
    assert_equal '"a\\"b c"', q.quote('a"b c')
    assert_equal '"C:\\dir with space\\\\"', q.quote('C:\\dir with space\\')
  end

  def test_no_shell_injection_and_unicode_args
    d = Dir.mktmpdir
    argv_log = File.join(d, 'argv.json')
    evil = File.join(d, 'ghế; rm -rf $HOME $(touch PWNED) `id` & del x.fbx')
    r = SL::BlenderRunner.new
    ENV['FAKE_BLENDER_ARGV_LOG'] = argv_log
    ENV['FAKE_BLENDER_MODE'] = 'ok'
    id = r.start([FAKE_BLENDER, '--background', evil], timeout: 20, log_path: File.join(d, 'l.log'))
    wait_until(20) { r.poll(id).state != :running }
    assert_equal [File.join('--background'), evil], JSON.parse(File.read(argv_log, encoding: 'UTF-8'))
    refute File.exist?(File.join(Dir.pwd, 'PWNED')), 'không chạy qua shell'
  ensure
    ENV.delete('FAKE_BLENDER_ARGV_LOG')
  end

  def test_timeout_and_cancel_kill_process
    d = Dir.mktmpdir
    r = SL::BlenderRunner.new
    ENV['FAKE_BLENDER_MODE'] = 'hang'
    id = r.start([FAKE_BLENDER], timeout: 1, log_path: File.join(d, 'a.log'))
    t0 = Time.now
    wait_until(10) { r.poll(id).state != :running }
    assert_equal :timeout, r.poll(id).state
    assert Time.now - t0 < 5
    id2 = r.start([FAKE_BLENDER], timeout: 0, log_path: File.join(d, 'b.log'))
    r.cancel(id2)
    assert_equal :cancelled, r.poll(id2).state
    pid = r.instance_variable_get(:@jobs)[id2].pid
    sleep 0.2
    assert_raises(Errno::ESRCH, Errno::ECHILD) { Process.kill(0, pid) }
  ensure
    ENV['FAKE_BLENDER_MODE'] = 'ok'
  end
end

class TestConverterManager < Minitest::Test
  def setup
    @data = Dir.mktmpdir('conv_')
    @settings = SL::Settings.new(File.join(@data, 'settings.json'))
    @cm = SL::ConverterManager.new(settings: @settings, data_root: @data,
                                   script: File.join(SRC, 'mt_smart_library', 'convert', 'convert_model.py'))
    @input = File.join(@data, 'Sofa góc.fbx')
    File.write(@input, 'FBX binary giả lập ' + rand.to_s)
    ENV['FAKE_BLENDER_MODE'] = 'ok'
  end

  def teardown
    ENV['FAKE_BLENDER_MODE'] = 'ok'
  end

  def run_convert(input = @input)
    res = nil
    @cm.convert(input) { |*a| res = a }
    wait_until(30) { @cm.poll; res }
    res
  end

  def test_detect_then_convert_then_cache
    st = nil
    @cm.detect(preferred: FAKE_BLENDER) { |s| st = s }
    wait_until(20) { @cm.poll; st }
    assert st['ok'], st.inspect
    assert_equal '4.5.3 LTS', st['version']
    assert @settings['converter']['blender_ok']
    kind, dae, rep = run_convert
    assert_equal :ok, kind, [dae, rep].inspect
    assert File.file?(dae)
    assert_includes File.read(dae), 'meter="1"'
    assert_equal 1200, rep['polygons']
    assert_equal [1.2, 0.8, 0.75], rep['dimensions_m']
    assert_equal 1, rep['textures'], 'texture nhúng được ghi ra file'
    assert(rep['warnings'].any? { |w| w.include?('Thiếu file texture') }, 'texture rời bị thiếu được cảnh báo, không âm thầm bỏ qua')
    assert File.file?(File.join(File.dirname(dae), 'textures', 'base_color.png'))
    refute Dir.glob(File.join(@data, 'convert_cache', '*.part*')).any?, 'không để lại thư mục tạm'
    t0 = Time.now
    kind2, dae2, rep2 = run_convert
    assert_equal :ok, kind2
    assert_equal dae, dae2
    assert rep2['cached'], 'lần 2 dùng cache, không chạy Blender'
    assert Time.now - t0 < 0.5
  end

  def test_blender5_rejected_and_need_blender
    ENV['FAKE_BLENDER_MODE'] = 'v5'
    @settings.data['converter']['blender_path'] = FAKE_BLENDER
    old_path = ENV['PATH']
    ENV["PATH"] = File.dirname(`which python3`.strip) # chỉ còn python3 (cho Blender giả), không có blender
    res = run_convert
    assert_equal :need_blender, res[0]
    assert_match(/không còn hỗ trợ xuất DAE/, res[1])
    refute @settings['converter']['blender_ok']
  ensure
    ENV['PATH'] = old_path
  end

  def test_no_blender_anywhere
    old_path = ENV['PATH']
    ENV["PATH"] = File.dirname(`which python3`.strip) # chỉ còn python3 (cho Blender giả), không có blender
    @settings.data['converter']['blender_path'] = ''
    res = run_convert
    assert_equal :need_blender, res[0]
    assert_match(/Chưa tìm thấy Blender/, res[1])
  ensure
    ENV['PATH'] = old_path
  end

  def ok_blender
    @settings.data['converter'].merge!('blender_path' => FAKE_BLENDER, 'blender_ok' => true, 'blender_version' => '4.5.3')
  end

  def test_no_geometry_and_crash_and_timeout
    ok_blender
    ENV['FAKE_BLENDER_MODE'] = 'nogeom'
    k, msg = run_convert
    assert_equal :error, k
    assert_match(/không có mặt/, msg)
    ENV['FAKE_BLENDER_MODE'] = 'crash'
    File.write(@input, 'khác ' + rand.to_s)
    k, msg = run_convert
    assert_equal :error, k
    assert_match(/mã 7/, msg)
    ENV['FAKE_BLENDER_MODE'] = 'hang'
    @settings.data['converter']['timeout'] = 1
    File.write(@input, 'khác nữa ' + rand.to_s)
    k, msg = run_convert
    assert_equal :error, k
    assert_match(/quá thời gian/, msg)
    assert_empty Dir.glob(File.join(@data, 'convert_cache', '*')), 'lỗi không để lại rác trong cache'
  end

  def test_cancel
    ok_blender
    ENV['FAKE_BLENDER_MODE'] = 'hang'
    res = nil
    @cm.convert(@input) { |*a| res = a }
    @cm.cancel_all
    wait_until(10) { @cm.poll; res }
    assert_equal [:cancelled], res
  end
end

class TestImportManager < Minitest::Test
  IM = SL::ImportManager
  def test_routes
    { 'a.skp' => :skp, 'a.GLB' => :gltf, 'a.gltf' => :gltf, 'a.dae' => :dae, 'a.fbx' => :convert, 'a.obj' => :convert,
      'a.usdz' => :convert, 'a.blend' => :convert, 'a.3ds' => :native, 'a.stl' => :native, 'a.zip' => :zip, 'a.exe' => :unsupported }.each do |f, r|
      assert_equal r, IM.route(f), f
    end
  end

  def test_zip_extract_pick_and_reject
    d = Dir.mktmpdir
    z = File.join(d, 'm.zip')
    script = "import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\nz.writestr('model/scene.obj','o')\nz.writestr('model/scene.mtl','m')\n" \
             "z.writestr('model/textures/wood.jpg','j')\nz.writestr('model/scene.glb','g'*100)\nz.writestr('__MACOSX/._x','x')\nz.close()\n"
    Open3.capture2e('python3', '-c', script, z)
    out = IM.extract_zip(z, File.join(d, 'x'))
    assert File.file?(File.join(out, 'model', 'textures', 'wood.jpg')), 'giữ texture trong thư mục con'
    refute File.exist?(File.join(out, '__MACOSX'))
    assert_equal 'scene.glb', File.basename(IM.pick_model(out)), 'ưu tiên GLB hơn OBJ'
    evil = File.join(d, 'e.zip')
    Open3.capture2e('python3', '-c', "import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\nz.writestr('../../evil.txt','x')\nz.close()", evil)
    assert_raises(StandardError) { IM.extract_zip(evil, File.join(d, 'y')) }
    refute File.exist?(File.join(d, 'evil.txt'))
  end
end

# SketchUp giả lập cho DefinitionList#import
class ImpBounds
  def initialize(w, h, d); @w = w; @h = h; @d = d; end
  def width; @w; end
  def height; @h; end
  def depth; @d; end
end
class ImpDef
  attr_accessor :name
  attr_reader :bounds
  def initialize(b); @bounds = b; @name = 'x'; end
end
class ImpModel
  attr_reader :ops, :placed, :definitions
  def initialize(fail: false, size_in: [47.2, 31.5, 29.5])
    @ops = []
    @placed = []
    f = fail
    sz = size_in
    @definitions = Object.new
    @definitions.define_singleton_method(:import) { |p| raise 'Lỗi nhập DAE' if f; ImpDef.new(ImpBounds.new(*sz)) }
    @definitions.define_singleton_method(:unique_name) { |n| n + '#1' }
  end
  def start_operation(*a); @ops << [:start, *a]; end
  def commit_operation; @ops << [:commit]; end
  def abort_operation; @ops << [:abort]; end
  def place_component(d, r); @placed << [d.name, r]; end
end

class TestImportComponent < Minitest::Test
  def test_import_place_undo_and_size_check
    Sketchup.model = ImpModel.new
    d, warn = SL::ImportManager.import_component('/x/model.dae', name: 'Sofa góc', expected_m: [1.2, 0.8, 0.75])
    assert_equal 'Sofa góc#1', d.name
    assert_equal [[:start, 'MT Smart Library: chèn model', true], [:commit]], Sketchup.model.ops
    assert_equal [['Sofa góc#1', false]], Sketchup.model.placed
    assert_empty warn, 'kích thước khớp file gốc'
    Sketchup.model = ImpModel.new(size_in: [4720, 3150, 2950])
    _d, warn = SL::ImportManager.import_component('/x/model.dae', name: 'S', expected_m: [1.2, 0.8, 0.75])
    assert(warn.any? { |w| w.include?('lệch') }, 'cảnh báo khi kích thước sai đơn vị')
    Sketchup.model = ImpModel.new(fail: true)
    assert_raises(RuntimeError) { SL::ImportManager.import_component('/x/bad.dae', name: 'S') }
    assert_equal [[:start, 'MT Smart Library: chèn model', true], [:abort]], Sketchup.model.ops, 'lỗi -> hoàn tác, không rác'
    assert_empty Sketchup.model.placed
  ensure
    Sketchup.model = nil
  end
end

class TestAppConvertFlow < Minitest::Test
  def test_click_insert_fbx_converts_and_places
    SL::Paths.reset!
    data = Dir.mktmpdir('appconv_')
    ENV['MT_SMART_LIBRARY_DATA'] = data
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    UI.timers.clear
    Sketchup.model = ImpModel.new
    ENV['FAKE_BLENDER_MODE'] = 'ok'
    app = SL::App.new
    app.settings.data['converter'].merge!('blender_path' => FAKE_BLENDER, 'blender_ok' => true)
    dl = SL::Paths.sub('downloads', 'sketchfab', 'c' * 32)
    FileUtils.mkdir_p(dl)
    fbx = File.join(dl, 'Ghế thư giãn.fbx')
    File.write(fbx, 'fbx')
    app.insert_path(fbx)
    300.times { UI.run_timers; break if Sketchup.model.placed.any?; sleep 0.02 }
    assert_equal [['Ghế thư giãn#1', false]], Sketchup.model.placed
    assert_equal [[:start, 'MT Smart Library: chèn model', true], [:commit]], Sketchup.model.ops
    refute app.insert_path('/etc/passwd.fbx'), 'chỉ cho chèn file trong thư mục tải về qua giao diện'
  ensure
    SL::Paths.reset!
    Sketchup.model = nil
  end
end
