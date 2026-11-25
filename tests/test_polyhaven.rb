# frozen_string_literal: true
require_relative 'test_helper'
require 'digest'
QN = SL::QueryNormalizer unless defined?(QN)

PH_CATALOG = JSON.generate(
  'ArmChair_01' => { 'name' => 'Arm Chair 01', 'type' => 2, 'categories' => %w[furniture seating],
                     'tags' => %w[gothic vintage chair furniture couch wood], 'authors' => { 'Kirill Sannikov' => 'All' },
                     'polycount' => 5626, 'download_count' => 33_200, 'category' => 'Furniture/Seating/Chairs',
                     'thumbnail_url' => 'https://cdn.polyhaven.com/asset_img/thumbs/ArmChair_01.png?width=256' },
  'Barrel_01' => { 'name' => 'Barrel_01', 'type' => 2, 'categories' => %w[industrial containers], 'tags' => %w[barrel oil],
                   'authors' => { 'Jorge' => 'All' }, 'download_count' => 61_145, 'category' => 'Containers & Storage/Barrels',
                   'thumbnail_url' => 'https://evil.example.com/x.png' },
  'Sofa_02' => { 'name' => 'Sofa 02', 'type' => 2, 'categories' => %w[furniture seating], 'tags' => %w[sofa couch modern],
                 'authors' => { 'A' => 'All' }, 'download_count' => 100, 'category' => 'Furniture/Seating/Sofas',
                 'thumbnail_url' => 'https://cdn.polyhaven.com/asset_img/thumbs/Sofa_02.png' },
  '../bad' => { 'name' => 'x', 'type' => 2 }
)

def ph_files(gltf_body, tex_body, bin_body, res: '1k', host: 'dl.polyhaven.org', rel: 'textures/Armchair_01_diff_1k.jpg')
  JSON.generate('gltf' => { res => { 'gltf' => {
    'url' => "https://#{host}/file/ph-assets/Models/gltf/#{res}/ArmChair_01/ArmChair_01_#{res}.gltf",
    'size' => gltf_body.bytesize, 'md5' => Digest::MD5.hexdigest(gltf_body),
    'include' => {
      rel => { 'url' => 'https://dl.polyhaven.org/file/ph-assets/Models/jpg/1k/ArmChair_01/Armchair_01_diff_1k.jpg',
               'size' => tex_body.bytesize, 'md5' => Digest::MD5.hexdigest(tex_body) },
      'ArmChair_01.bin' => { 'url' => 'https://dl.polyhaven.org/file/ph-assets/Models/gltf/4k/ArmChair_01/ArmChair_01.bin',
                             'size' => bin_body.bytesize, 'md5' => Digest::MD5.hexdigest(bin_body) }
    }
  } } }, 'fbx' => {})
end

# HTTP giả: trả JSON theo URL hoặc ghi file khi có dest; có thể giả lập mất mạng.
class PhHttp
  attr_reader :urls
  attr_accessor :offline, :bodies
  def initialize(bodies); @bodies = bodies; @urls = []; @offline = false; end
  def request(opts, &cb)
    @urls << opts[:url]
    if @offline
      return cb.call(SL::HttpClient::Result.new(false, 0, nil, {}, :network, 'offline', nil, opts[:url]))
    end
    body = @bodies.find { |k, _| opts[:url].include?(k) }&.last
    return cb.call(SL::HttpClient::Result.new(false, 404, '', {}, nil, nil, nil, opts[:url])) unless body
    if opts[:dest]
      FileUtils.mkdir_p(File.dirname(opts[:dest]))
      File.binwrite(opts[:dest], body)
      opts[:progress]['bytes'] = body.bytesize if opts[:progress]
      cb.call(SL::HttpClient::Result.new(true, 200, nil, {}, nil, nil, opts[:dest], opts[:url]))
    else
      cb.call(SL::HttpClient::Result.new(true, 200, body, {}, nil, nil, nil, opts[:url]))
    end
    1
  end
  def cancel(_); end
end

class TestPolyHaven < Minitest::Test
  def session(text, st)
    q = QN.analyze(text)
    SL::SearchManager::Session.new(1, q, [], q.primary_en, SL::Categories.find('all', []), [], 'all', 'all', {}, {}, st, 0, 0,
                                   QN.analyze(q.primary_en.to_s))
  end

  def test_parse_catalog_rejects_bad_ids_and_hosts
    list = SL::PolyHaven.parse_catalog(PH_CATALOG)
    assert_equal %w[ArmChair_01 Barrel_01 Sofa_02], list.map { |a| a['id'] }.sort
    arm = list.find { |a| a['id'] == 'ArmChair_01' }
    assert_equal ['Kirill Sannikov'], arm['authors']
    assert_match(%r{\Ahttps://cdn\.polyhaven\.com/}, arm['thumb'])
    assert_nil list.find { |a| a['id'] == 'Barrel_01' }['thumb'], 'ảnh ngoài cdn.polyhaven.com bị bỏ'
  end

  def test_pick_gltf_resolution_and_safety
    plan = SL::PolyHaven.pick_gltf(ph_files('g', 'tt', 'bbb'))
    assert_equal '1k', plan['resolution'], 'không có 2k thì lấy 1k'
    assert_equal 'ArmChair_01_1k.gltf', plan['files'][0]['rel']
    assert_equal %w[ArmChair_01_1k.gltf textures/Armchair_01_diff_1k.jpg ArmChair_01.bin].sort, plan['files'].map { |f| f['rel'] }.sort
    assert_equal 6, plan['total']
    assert_raises(RuntimeError) { SL::PolyHaven.pick_gltf(ph_files('g', 't', 'b', rel: '../../evil.dll')) }
    assert_raises(RuntimeError) { SL::PolyHaven.pick_gltf(ph_files('g', 't', 'b', host: 'evil.com')) }
    assert_raises(RuntimeError) { SL::PolyHaven.pick_gltf(JSON.generate('fbx' => {})) }
    assert_raises(RuntimeError) { SL::PolyHaven.files_url('a/../b') }
  end

  def test_provider_vietnamese_search_cache_and_offline
    dir = Dir.mktmpdir
    st = SL::Settings.new(File.join(dir, 's.json'))
    http = PhHttp.new('assets?type=models' => PH_CATALOG)
    p = SL::Providers::PolyHavenProvider.new(http, dir)
    out = nil
    p.search(session('ghế sofa', st), nil) { |r| out = r }
    assert_nil out['error']
    titles = out['items'].map { |i| i['title'] }
    assert_includes titles, 'Sofa 02', 'tiếng Việt → sofa/couch'
    refute_includes titles, 'Barrel_01', 'không trả kết quả không liên quan'
    it = out['items'].find { |i| i['title'] == 'Sofa 02' }
    assert_equal 'Poly Haven', it['source_label']
    assert_equal 'ph-Sofa_02', it['uid']
    assert it['insertable'] && it['free'] && it['downloadable']
    assert_equal 'https://polyhaven.com/a/Sofa_02', it['url']
    p.search(session('ghế', st), nil) { |r| out = r }
    assert_includes out['items'].map { |i| i['title'] }, 'Arm Chair 01'
    assert_equal 1, http.urls.size, 'danh mục tải 1 lần'
    # Phiên mới (khởi động lại SketchUp), mất mạng: vẫn tìm bằng bản lưu đĩa
    http.offline = true
    p2 = SL::Providers::PolyHavenProvider.new(http, dir)
    p2.search(session('sofa', st), nil) { |r| out = r }
    assert_includes out['items'].map { |i| i['title'] }, 'Sofa 02'
    assert_equal 1, http.urls.size, 'cache đĩa còn hạn: không gọi mạng'
    # Không có cache + mất mạng → báo lỗi rõ, không treo
    p3 = SL::Providers::PolyHavenProvider.new(http, Dir.mktmpdir)
    p3.search(session('sofa', st), nil) { |r| out = r }
    assert out['error'] && out['items'].empty?
  end

  def test_toggle_is_remembered
    dir = Dir.mktmpdir
    path = File.join(dir, 's.json')
    st = SL::Settings.new(path)
    assert_equal true, st['sources']['polyhaven'], 'mặc định bật'
    st.apply_ui('sources' => { 'polyhaven' => false })
    st.save
    st2 = SL::Settings.new(path)
    assert_equal false, st2['sources']['polyhaven']
    assert_equal true, st2['sources']['sketchfab']
    refute SL::Providers::PolyHavenProvider.new(nil, dir).applicable?(session('sofa', st2), st2)
  end

  def test_app_insert_downloads_verifies_md5_and_inserts
    SL::Paths.reset!
    data = Dir.mktmpdir('appdata_')
    ENV['MT_SMART_LIBRARY_DATA'] = data
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    Sketchup.model = nil
    app = SL::App.new
    g = '{"asset":{"version":"2.0"}}'
    tex = 'JPEGDATA'
    bin = 'BINDATA!'
    http = PhHttp.new('/files/ArmChair_01' => ph_files(g, tex, bin), '_1k.gltf' => g, 'diff_1k.jpg' => tex, 'ArmChair_01.bin' => bin)
    app.instance_variable_set(:@http, http)
    inserted = []
    app.define_singleton_method(:smart_insert) { |path, name: nil| inserted << [path, name] }
    item = { 'source' => 'polyhaven', 'uid' => 'ph-ArmChair_01', 'title' => 'Arm Chair 01', 'author' => 'Kirill Sannikov',
             'url' => 'https://polyhaven.com/a/ArmChair_01', 'key' => 'polyhaven:ph-ArmChair_01' }
    app.insert_polyhaven(item)
    folder = File.join(data, 'downloads', 'polyhaven', 'ArmChair_01')
    assert_equal [[File.join(folder, 'ArmChair_01_1k.gltf'), 'Arm Chair 01']], inserted
    assert_equal tex, File.binread(File.join(folder, 'textures', 'Armchair_01_diff_1k.jpg')), 'giữ đúng thư mục textures/'
    assert_match(/CC0/, File.read(File.join(folder, 'ATTRIBUTION.txt'), encoding: 'UTF-8'))
    n = http.urls.size
    app.insert_polyhaven(item)
    assert_equal n, http.urls.size, 'lần 2 chèn lại từ file đã tải'
    assert_equal 2, inserted.size
    # File hỏng (sai MD5) → báo lỗi, không chèn
    bad = PhHttp.new('/files/ArmChair_01' => ph_files(g, tex, bin), '_1k.gltf' => g, 'diff_1k.jpg' => 'CORRUPT', 'ArmChair_01.bin' => bin)
    app2 = SL::App.new
    app2.instance_variable_set(:@http, bad)
    ins2 = []
    app2.define_singleton_method(:smart_insert) { |path, name: nil| ins2 << path }
    FileUtils.rm_rf(folder)
    app2.insert_polyhaven(item)
    assert_empty ins2
    assert_equal 'error', app2.instance_variable_get(:@downloads)['ph-ArmChair_01']['state']
  ensure
    SL::Paths.reset!
  end
end
