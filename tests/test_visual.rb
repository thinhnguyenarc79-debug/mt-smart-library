# frozen_string_literal: true
require_relative 'test_helper'
require 'digest'
require 'open3'

# Kiểm thử MT VISUAL SEARCH ENGINE chạy THẬT tiến trình Python + ONNX Runtime với bộ mô hình ONNX nhỏ cùng giao diện CLIP
# (tests/fixtures/make_tiny_clip.py: vector = màu trung bình lưới 4×4). Không kiểm được chất lượng CLIP thật (máy test không tải được).
PY = `which python3`.strip
ALL_KW = %w[altar armchair bathtub bed bench bookshelf cabinet car carpet ceiling chair chandelier closet couch curtain decor desk dresser
            drapes fireplace kitchen mirror nightstand ottoman oven painting piano plant pouf refrigerator rug sconce shelf sideboard sink
            sofa staircase stairs stool table toilet tree vanity vase wardrobe washbasin window downlight].freeze

def ort_ok?
  !PY.empty? && system(PY, '-c', 'import onnxruntime, numpy, PIL', out: File::NULL, err: File::NULL)
end

def draw(path, spec)
  code = <<~PY
    import sys, json
    from PIL import Image, ImageDraw
    spec = json.loads(sys.argv[2]); im = Image.new('RGB', (400, 400), 'white'); d = ImageDraw.Draw(im)
    for s in spec:
        box = tuple(s['box'])
        (d.ellipse if s['shape'] == 'circle' else d.rectangle)(box, fill=s['color'])
    im.save(sys.argv[1])
  PY
  system(PY, '-c', code, path, JSON.generate(spec)) or raise 'draw failed'
  path
end

# File SKP giả: dữ liệu rác + ảnh PNG xem trước nhúng (giống cấu trúc ảnh preview trong file SketchUp).
def fake_skp(path, png)
  File.binwrite(path, "SketchUp Model\x00".b + Random.new(3).bytes(2000) + File.binread(png) + Random.new(4).bytes(500))
  path
end

class OnlineFake < SL::Providers::BaseProvider
  def initialize(items); super('sketchfab', 'Sketchfab'); @items = items; end
  def online?; true; end
  def applicable?(s, _st); !s.online_q.to_s.empty?; end
  def search(_s, _t, &done); done.call('items' => @items.map(&:dup), 'next' => nil, 'error' => nil); end
end

class TestVisualSearch < Minitest::Test
  def setup
    skip 'cần python3 + onnxruntime + numpy + pillow' unless ort_ok?
    SL::Paths.reset!
    @data = Dir.mktmpdir('vs_')
    @models = File.join(@data, 'tiny_models')
    system(PY, File.join(__dir__, 'fixtures', 'make_tiny_clip.py'), @models) or raise 'tiny model'
    ENV['MT_AI_PYTHON'] = PY
    ENV['MT_AI_MODELS'] = @models
    @img = File.join(@data, 'img')
    FileUtils.mkdir_p(@img)
    lib = File.join(@data, 'lib')
    FileUtils.mkdir_p(lib)
    red_c = draw("#{@img}/red_circle.png", [{ 'shape' => 'circle', 'box' => [80, 80, 320, 320], 'color' => 'red' }])
    blue_c = draw("#{@img}/blue_circle.png", [{ 'shape' => 'circle', 'box' => [80, 80, 320, 320], 'color' => 'blue' }])
    red_r = draw("#{@img}/red_rect.png", [{ 'shape' => 'rect', 'box' => [20, 150, 380, 250], 'color' => 'red' }])
    files = { 'Bàn tròn đỏ' => red_c, 'Bàn tròn xanh' => blue_c, 'Bàn chữ nhật đỏ' => red_r }
    entries = files.map { |n, png| SL::SearchIndex.build_entry(fake_skp("#{lib}/#{n}.skp", png), 3000, 1, lib) }
    File.binwrite("#{lib}/Không ảnh.skp", 'no preview here')
    entries << SL::SearchIndex.build_entry("#{lib}/Không ảnh.skp", 15, 1, lib)
    @index = SL::SearchIndex.new
    @index.replace(entries)
    @settings = SL::Settings.new(File.join(@data, 's.json'))
    @thumbs = SL::ThumbService.new(File.join(@data, 'thumbs')) { false }
    @runner = SL::BlenderRunner.new
    @http = Object.new
    @rt = SL::RuntimeManager.new(http: @http, runner: @runner, data_root: @data, code_dir: File.join(SRC, 'mt_smart_library'))
    @rt.cfg['model']['min_score'] = 0.0 # mô hình thử nghiệm có thang điểm khác CLIP
    @events = []
  end

  def teardown
    @rt&.stop
    ENV.delete('MT_AI_PYTHON')
    ENV.delete('MT_AI_MODELS')
    SL::Paths.reset!
  end

  def manager(online_items = [])
    SL::VisualSearchManager.new(runtime: @rt, index: @index, thumbs: @thumbs, online_providers: [OnlineFake.new(online_items)],
                                settings: @settings, emit: ->(t, p) { @events << [t, p] })
  end

  def pump(vm, secs = 40)
    t0 = Time.now
    until Time.now - t0 > secs
      @rt.poll
      vm.poll
      return if yield
      sleep 0.05
    end
    flunk "hết giờ chờ — sự kiện: #{@events.map(&:first).last(8)}"
  end

  def events(type)
    @events.select { |t, _| t == type }.map(&:last)
  end

  def index_all(vm)
    vm.sync_index
    pump(vm) { (r = events('vs_index').last) && !r['running'] && r['indexed'] }
  end

  def test_local_visual_ranking_index_and_no_thumb
    vm = manager
    index_all(vm)
    st = events('vs_index').last
    assert_equal 3, st['indexed']
    assert_equal 1, st['no_thumb'], 'model không có thumbnail được tách riêng, không giả lập vector'
    q = draw("#{@img}/query.png", [{ 'shape' => 'circle', 'box' => [60, 60, 340, 340], 'color' => 'red' }])
    vm.start(q)
    pump(vm) { events('vs_state').any? { |s| s['state'] == 'done' } }
    res = events('sr_update').last
    assert res['visual']
    titles = res['items'].map { |i| i['title'] }
    assert_equal 'Bàn tròn đỏ', titles.first, 'giống nhất lên đầu'
    refute_includes titles, 'Không ảnh'
    scores = res['items'].map { |i| i['vscore'] }
    assert_equal scores.sort.reverse, scores, 'xếp theo độ tương đồng giảm dần'
    assert res['items'].all? { |i| i['insertable'] && i['key'].start_with?('local:') }
    assert vm.item(res['items'][0]['key']), 'CHÈN tìm được model từ kết quả ảnh'
    refute events('vs_state').any? { |s| s['state'] == 'need_runtime' }, 'không cần OpenAI / cài thêm'
    # Không tính lại khi thư viện không đổi
    @events.clear
    vm.sync_index
    assert_empty events('vs_index'), 'chỉ mục còn mới: không gửi lại công việc'
  end

  def test_crop_region_finds_object_in_scene
    vm = manager
    index_all(vm)
    scene = draw("#{@img}/scene.png", [{ 'shape' => 'rect', 'box' => [210, 150, 395, 250], 'color' => 'blue' },
                                        { 'shape' => 'circle', 'box' => [10, 110, 190, 290], 'color' => 'red' }])
    vm.start(scene, crop: [0.0, 0.2, 0.5, 0.8])
    pump(vm) { events('vs_state').any? { |s| s['state'] == 'done' } }
    assert_equal 'Bàn tròn đỏ', events('sr_update').last['items'].first['title'], 'cắt vùng: tìm đúng món đồ được chọn'
  end

  def test_online_candidates_ranked_by_thumbnail_similarity
    # Ảnh thumbnail online được lưu sẵn trong cache (máy test không có mạng): đúng tên file worker dùng (sha1 của URL).
    cache = File.join(@rt.work_dir, 'online_thumbs')
    FileUtils.mkdir_p(cache)
    online = { 'https://media.sketchfab.com/a/red_round.png' => "#{@img}/red_circle.png",
               'https://media.sketchfab.com/a/red_long.png' => "#{@img}/red_rect.png" }
    online.each { |u, f| FileUtils.cp(f, File.join(cache, Digest::SHA1.hexdigest(u) + '.img')) }
    items = [
      { 'source' => 'sketchfab', 'source_label' => 'Sketchfab', 'uid' => 'u1', 'title' => 'Round thing', 'tags' => ALL_KW,
        'thumb' => online.keys[0], 'downloadable' => true, 'free' => true, 'insertable' => false, 'author' => 'A' },
      { 'source' => 'sketchfab', 'source_label' => 'Sketchfab', 'uid' => 'u2', 'title' => 'Long thing', 'tags' => ALL_KW,
        'thumb' => online.keys[1], 'downloadable' => true, 'free' => true, 'insertable' => false, 'author' => 'B' },
      { 'source' => 'sketchfab', 'source_label' => 'Sketchfab', 'uid' => 'u3', 'title' => 'Evil host', 'tags' => ALL_KW,
        'thumb' => 'https://evil.example.com/x.png', 'downloadable' => true, 'author' => 'C' }
    ]
    vm = manager(items)
    q = draw("#{@img}/q2.png", [{ 'shape' => 'circle', 'box' => [70, 70, 330, 330], 'color' => 'red' }])
    vm.start(q)
    pump(vm) { events('vs_state').any? { |s| s['state'] == 'done' } }
    res = events('sr_update').last
    online_items = res['items'].reject { |i| i['source'] == 'local' }
    assert_equal ['Round thing', 'Long thing'], online_items.map { |i| i['title'] }, 'online xếp theo ảnh thật; host lạ bị bỏ'
    assert online_items.all? { |i| i['vscore'].is_a?(Numeric) }
    all = res['items'].map { |i| i['vscore'] }
    assert_equal all.sort.reverse, all, 'online và máy tính trộn chung theo điểm ảnh'
    assert events('vs_state').any? { |s| s['state'] == 'comparing' }
  end

  def test_cancel_midway_and_runtime_missing
    vm = manager
    q = draw("#{@img}/q3.png", [{ 'shape' => 'circle', 'box' => [70, 70, 330, 330], 'color' => 'red' }])
    vm.start(q)
    vm.cancel
    assert_equal 'cancelled', events('vs_state').last['state']
    refute vm.active?
    ENV.delete('MT_AI_PYTHON')
    rt2 = SL::RuntimeManager.new(http: @http, runner: @runner, data_root: Dir.mktmpdir, code_dir: File.join(SRC, 'mt_smart_library'))
    vm2 = SL::VisualSearchManager.new(runtime: rt2, index: @index, thumbs: @thumbs, online_providers: [], settings: @settings,
                                      emit: ->(t, p) { @events << [t, p] })
    vm2.start(q)
    st = events('vs_state').last
    assert_equal 'need_runtime', st['state'], 'chưa cài bộ AI: hỏi cài 1 lần (không chuyển sang OpenAI)'
    assert_equal 330, st['download_mb']
  end
end

# Cài đặt bộ AI: tải Python nhúng → bật site → pip → mô hình (kiểm SHA256 / git SHA1). HTTP và tiến trình giả lập.
class FileHttp
  def initialize(map); @map = map; @urls = []; end
  attr_reader :urls
  def request(opts, &cb)
    @urls << opts[:url]
    body = @map[opts[:url]]
    return cb.call(SL::HttpClient::Result.new(false, 404, '', {}, nil, nil, nil, opts[:url])) unless body
    FileUtils.mkdir_p(File.dirname(opts[:dest]))
    File.binwrite(opts[:dest], body)
    cb.call(SL::HttpClient::Result.new(true, 200, nil, {}, nil, nil, opts[:dest], opts[:url]))
  end
end

class OkRunner
  Job = Struct.new(:state, :exit_code)
  attr_reader :cmds
  def initialize(fail_first_pip: false); @cmds = []; @fail = fail_first_pip; end
  def start(argv, **_o); @cmds << argv; argv; end
  def poll(argv)
    if @fail && argv.include?('onnxruntime-directml') then Job.new(:failed, 1) else Job.new(:done, 0) end
  end
end

class TestRuntimeInstall < Minitest::Test
  def test_install_flow_verifies_hashes
    skip 'cần lệnh zip' unless system('which zip > /dev/null 2>&1')
    ENV.delete('MT_AI_PYTHON')
    ENV.delete('MT_AI_MODELS')
    code = Dir.mktmpdir('code_')
    FileUtils.mkdir_p(File.join(code, 'ai_runtime'))
    vis = 'VISION' * 100
    voc = '{"a":1}'
    cfg = JSON.parse(File.read(File.join(SRC, 'mt_smart_library', 'ai_runtime', 'model_config.json')))
    cfg['model']['files'] = [
      { 'name' => 'vision_model.onnx', 'url' => 'https://h/v', 'size' => vis.bytesize, 'sha256' => Digest::SHA256.hexdigest(vis) },
      { 'name' => 'vocab.json', 'url' => 'https://h/voc', 'size' => voc.bytesize, 'git_sha1' => Digest::SHA1.hexdigest("blob #{voc.bytesize}\0#{voc}") }
    ]
    File.write(File.join(code, 'ai_runtime', 'model_config.json'), JSON.generate(cfg))
    src = Dir.mktmpdir
    File.write(File.join(src, 'python311._pth'), "python311.zip\n.\n#import site\n")
    File.write(File.join(src, 'python.exe'), 'MZ')
    File.write(File.join(src, 'bin_python3'), 'x')
    zip = File.join(src, 'py.zip')
    Dir.chdir(src) { system('zip', '-q', zip, 'python311._pth', 'python.exe') }
    http = FileHttp.new(cfg['runtime']['python_zip'] => File.binread(zip), cfg['runtime']['get_pip'] => 'print(1)',
                        'https://h/v' => vis, 'https://h/voc' => voc)
    runner = OkRunner.new(fail_first_pip: true)
    data = Dir.mktmpdir
    rt = SL::RuntimeManager.new(http: http, runner: runner, data_root: data, code_dir: code)
    rt.define_singleton_method(:python_exe) { File.join(python_dir, 'python.exe') }
    refute rt.installed?
    result = nil
    rt.install { |ok, err| result = [ok, err] }
    200.times do
      break if result
      rt.poll
      rt.threads.each { |t| t.join(0.05) }
    end
    assert_equal [true, nil], result
    assert rt.installed?
    pth = File.read(File.join(rt.python_dir, 'python311._pth'))
    assert_includes pth, "import site\r\n"
    refute_includes pth, '#import site'
    assert_includes pth, 'Lib\\site-packages'
    pips = runner.cmds.select { |c| c.include?('pip') && c.include?('install') }
    assert_equal 2, pips.size, 'không cài được bản DirectML → tự cài bản CPU'
    assert_includes pips.last, 'onnxruntime'
    assert(runner.cmds.none? { |c| c.join(' ') =~ /[;&|]/ }, 'lệnh chạy dạng danh sách đối số')
    # File mô hình hỏng → bị xóa, báo lỗi
    data2 = Dir.mktmpdir
    http2 = FileHttp.new(cfg['runtime']['python_zip'] => File.binread(zip), cfg['runtime']['get_pip'] => 'x',
                         'https://h/v' => 'X' * vis.bytesize, 'https://h/voc' => voc)
    rt2 = SL::RuntimeManager.new(http: http2, runner: OkRunner.new, data_root: data2, code_dir: code)
    rt2.define_singleton_method(:python_exe) { File.join(python_dir, 'python.exe') }
    result = nil
    rt2.install { |ok, err| result = [ok, err] }
    200.times do
      break if result
      rt2.poll
      rt2.threads.each { |t| t.join(0.05) }
    end
    refute result[0]
    assert_match(/không khớp mã kiểm tra/, result[1])
    refute File.exist?(File.join(rt2.models_dir, 'vision_model.onnx'))
    refute rt2.installed?
  end
end

# V1.0.10: GPU (DirectML) sập khi nạp vision model → không ảnh hưởng tìm kiếm; CPU mặc định; chống vòng lặp lỗi.
class TestVisualCrash < Minitest::Test
  def setup
    skip 'cần python3 + onnxruntime' unless ort_ok?
    @data = Dir.mktmpdir('vc_')
    @models = File.join(@data, 'm')
    system(PY, File.join(__dir__, 'fixtures', 'make_tiny_clip.py'), @models) or raise 'tiny'
    ENV['MT_AI_PYTHON'] = PY
    ENV['MT_AI_MODELS'] = @models
    @img = File.join(@data, 'q.png')
    draw(@img, [{ 'shape' => 'circle', 'box' => [60, 60, 340, 340], 'color' => 'red' }])
    @rt = SL::RuntimeManager.new(http: Object.new, runner: SL::BlenderRunner.new, data_root: @data, code_dir: File.join(SRC, 'mt_smart_library'))
  end

  def teardown
    @rt&.stop
    %w[MT_AI_PYTHON MT_AI_MODELS MT_AI_TEST_CRASH].each { |k| ENV.delete(k) }
  end

  def run_job(secs = 40)
    res = nil
    @rt.submit('embed_query', { 'image' => @img, 'out_vec' => File.join(@data, "v#{rand(1e6)}.npy") }) { |r| res = r }
    t0 = Time.now
    until res || Time.now - t0 > secs
      @rt.poll
      sleep 0.05
    end
    res
  end

  def test_default_is_cpu
    assert_equal 'cpu', @rt.device_pref
    assert_equal 'cpu', @rt.effective_device
    st = SL::Settings.new(File.join(@data, 's.json'))
    assert_equal 'cpu', st['ai']['device'], 'cài đặt mặc định CPU'
    r = run_job
    assert r['ok'], r.inspect
    assert_match(/CPU/, File.read(@rt.worker_log))
  end

  def test_gpu_probe_crash_falls_back_to_cpu_and_logs
    ENV['MT_AI_TEST_CRASH'] = 'gpu' # giả lập access violation của DirectML
    @rt.device_pref = 'gpu'
    r = run_job
    assert r['ok'], "tìm vẫn chạy bằng CPU: #{r.inspect}"
    pr = @rt.gpu_probe
    refute pr['ok']
    refute_equal '0', pr['code']
    log = File.read(@rt.worker_log)
    assert_match(/Fatal Python error|Segmentation fault/, log, 'faulthandler ghi lỗi native')
    assert_match(/Kết quả kiểm tra GPU/, log)
    assert_match(/Khởi động tiến trình AI \(CPU\)/, log)
    assert_match(/GPU/, @rt.take_notice.to_s)
    assert_equal 'cpu', @rt.effective_device, 'đã ghi nhận GPU lỗi: lần sau dùng CPU ngay'
  end

  def test_gpu_worker_crash_restarts_on_cpu_and_resubmits
    ENV['MT_AI_TEST_CRASH'] = 'gpu'
    @rt.device_pref = 'gpu'
    FileUtils.mkdir_p(@rt.work_dir)
    File.write(@rt.gpu_probe_file, JSON.generate('ok' => true)) # giả sử bài kiểm tra từng đạt
    r = run_job
    assert r['ok'], "việc dở được gửi lại và chạy bằng CPU: #{r.inspect}"
    refute @rt.gpu_probe['ok']
    assert_match(/đã tự chuyển sang CPU/, @rt.take_notice)
  end

  def test_cpu_crash_loop_stops_and_cleans_jobs
    FileUtils.mkdir_p(@rt.jobs_dir)
    File.write(File.join(@rt.jobs_dir, 'stale_1.job.json'), '{"type":"probe"}')
    ENV['MT_AI_TEST_CRASH'] = 'cpu'
    r = run_job
    refute r['ok']
    assert r['broken']
    assert_match(/mã|0x|-?\d/, r['error'])
    refute @rt.available?, 'dừng hẳn, không tự tạo lại'
    assert_empty Dir.glob(File.join(@rt.jobs_dir, '*.job.json')), 'không còn việc tồn đọng'
    calls = 0
    @rt.submit('probe', {}) { |x| calls += 1; assert x['broken'] }
    assert_equal 1, calls, 'việc mới trả lỗi ngay, không khởi động lại tiến trình'
    ENV.delete('MT_AI_TEST_CRASH')
    @rt.reset_broken
    assert run_job['ok'], 'người dùng tìm lại sau khi sửa: chạy được'
  end
end
