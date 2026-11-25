# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'test_visual' # tiện ích chạy AI thật (python + onnxruntime) và vẽ ảnh

class SeqHttp
  attr_reader :urls
  def initialize(map); @map = map; @urls = []; end
  def request(opts, &cb)
    @urls << opts[:url]
    hit = @map.find { |k, _| opts[:url].include?(k) }
    code, body = hit ? hit[1] : [404, '']
    if opts[:dest] && code == 200
      FileUtils.mkdir_p(File.dirname(opts[:dest]))
      File.binwrite(opts[:dest], body)
    end
    cb.call(SL::HttpClient::Result.new(code == 200, code, opts[:dest] ? nil : body, {}, code.zero? ? :network : nil, 'x', opts[:dest], opts[:url]))
    1
  end
  def cancel(_); end
end

class TestSourceRegistry < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'sources.json')
    @reg = SL::SourceRegistry.new(@path, builtins: [{ 'id' => 'sketchfab', 'name' => 'Sketchfab', 'type' => 'website' }])
  end

  def test_crud_types_and_persistence
    w = @reg.add('url' => 'www.example-skp.com/', 'name' => '')
    assert_equal 'website', w['type']
    assert_equal 'https://www.example-skp.com', w['url']
    assert_equal 'example-skp.com', w['name']
    assert_equal 'unverified', w['method']
    fb = @reg.add('url' => 'https://www.facebook.com/groups/thuvien3d', 'type' => '')
    assert_equal 'facebook_group', fb['type']
    assert_equal 'open_only', fb['method']
    assert_equal 'facebook_page', @reg.add('url' => 'https://facebook.com/mtdesign')['type']
    assert_equal 'dropbox', @reg.add('url' => 'https://www.dropbox.com/scl/fo/abc')['type']
    assert_equal 'direct_link', @reg.find(@reg.custom.last['id'])['method']
    assert_equal 'gdrive', @reg.add('url' => 'https://drive.google.com/drive/folders/xyz')['type']
    assert_equal 'mega', @reg.add('url' => 'https://mega.nz/folder/abc')['type']
    assert_equal 'mediafire', @reg.add('url' => 'https://www.mediafire.com/folder/abc')['type']
    assert_equal 'onedrive', @reg.add('url' => 'https://1drv.ms/f/abc')['type']
    loc = @reg.add('url' => @dir, 'type' => 'local')
    assert_equal 'local', loc['method']
    assert_raises(RuntimeError) { @reg.add('url' => 'https://www.example-skp.com') }
    assert_raises(RuntimeError) { @reg.add('url' => 'not a url') }
    assert_raises(RuntimeError) { @reg.add('url' => '/no/such/dir', 'type' => 'local') }
    @reg.toggle(w['id'], false)
    @reg.update(fb['id'], 'name' => 'Nhóm thư viện 3D')
    reg2 = SL::SourceRegistry.new(@path, builtins: [{ 'id' => 'sketchfab', 'name' => 'Sketchfab', 'type' => 'website' }])
    assert_equal 9, reg2.custom.size
    refute reg2.find(w['id'])['enabled']
    assert_equal 'Nhóm thư viện 3D', reg2.find(fb['id'])['name']
    list = reg2.list
    assert list.first['builtin'], 'nguồn có sẵn nằm trong danh sách, không xóa được'
    reg2.delete(fb['id'])
    assert_nil reg2.find(fb['id'])
  end

  def test_export_import_json
    @reg.add('url' => 'https://a-skp.com', 'name' => 'A')
    @reg.add('url' => 'https://www.facebook.com/groups/g1')
    json = @reg.export_json
    data = JSON.parse(json)
    assert_equal 'mt-smart-library-sources', data['format']
    refute_includes json, '"id"', 'xuất không kèm id nội bộ'
    other = SL::SourceRegistry.new(File.join(@dir, 'b.json'))
    assert_equal 2, other.import_json(json)
    assert_equal 0, other.import_json(json), 'nhập lại không tạo trùng'
    assert_raises(RuntimeError) { other.import_json('{bad') }
    assert_raises(RuntimeError) { other.import_json('{"x":1}') }
    evil = JSON.generate('sources' => [{ 'url' => 'https://ok-site.vn', 'method' => 'wp_rest', 'status' => 'ok', 'id' => 'u_aaaaaaaaaa', 'eval' => 'x' }])
    other.import_json(evil)
    s = other.custom.last
    assert_match(/\Au_[0-9a-f]{10}\z/, s['id'])
    refute s.key?('eval')
  end
end

class TestSiteProbe < Minitest::Test
  def test_robots_rules
    r = "User-agent: *\nDisallow: /wp-admin/\nAllow: /wp-admin/admin-ajax.php\n\nUser-agent: GPTBot\nDisallow: /\n"
    assert SL::SiteProbe.robots_allow?(r, '/wp-json/wp/v2/posts')
    refute SL::SiteProbe.robots_allow?(r, '/wp-admin/x')
    assert SL::SiteProbe.robots_allow?(r, '/wp-admin/admin-ajax.php')
    refute SL::SiteProbe.robots_allow?("User-agent: *\nDisallow: /wp-json/\n", '/wp-json/wp/v2/posts')
    refute SL::SiteProbe.robots_allow?("User-agent: *\nDisallow: /\n", '/wp-json/wp/v2/posts')
    assert SL::SiteProbe.robots_allow?("User-agent: *\nDisallow: /*?s=\n", '/wp-json/wp/v2/posts')
    assert SL::SiteProbe.robots_allow?('', '/x')
    assert_equal 'example.com.vn', SL::SiteProbe.registrable('img.example.com.vn')
    assert_equal 'cgtips.org', SL::SiteProbe.registrable('sketchup.cgtips.org')
  end

  def probe(map)
    out = nil
    SL::SiteProbe.probe(SeqHttp.new(map), 'https://site.vn/') { |r| out = r }
    out
  end

  def test_probe_outcomes
    ok = probe('robots.txt' => [200, "User-agent: *\nDisallow: /wp-admin/\n"],
               '/wp-json/wp/v2/posts' => [200, JSON.generate([{ 'id' => 1, 'title' => { 'rendered' => 'Ghế sofa' } }])])
    assert_equal 'wp_rest', ok['method']
    assert_equal 'vi', ok['lang']
    assert_equal 'site.vn', ok['img_domain']
    assert_equal 'blocked', probe('robots.txt' => [200, "User-agent: *\nDisallow: /wp-json\n"])['status']
    assert_equal 'login', probe('/wp-json/' => [403, 'no'])['status']
    assert_equal 'no_api', probe('/wp-json/' => [200, '<html>shop</html>'])['status']
    assert_equal 'error', probe('/wp-json/' => [0, ''])['status']
  end
end

class TestLinkImport < Minitest::Test
  def test_classify
    d = SL::LinkImport.classify('https://www.dropbox.com/scl/fi/abc/sofa.skp?rlkey=xyz&dl=0')
    assert_equal :download, d[:kind]
    assert_includes d[:url], 'rlkey=xyz'
    assert_includes d[:url], 'dl=1'
    refute_includes d[:url], 'dl=0'
    assert_equal :download, SL::LinkImport.classify('https://cdn.example.com/models/ban%20an.zip')[:kind]
    assert_equal :open, SL::LinkImport.classify('https://www.facebook.com/groups/abc/posts/123')[:kind]
    assert_equal :open, SL::LinkImport.classify('https://drive.google.com/file/d/xyz/view')[:kind]
    assert_equal :open, SL::LinkImport.classify('https://mega.nz/file/abc')[:kind]
    assert_equal :open, SL::LinkImport.classify('https://www.mediafire.com/file/abc/x.zip/file')[:kind]
    assert_raises(RuntimeError) { SL::LinkImport.classify('::') }
  end

  def test_sniff
    dir = Dir.mktmpdir
    File.binwrite(z = File.join(dir, 'a'), "PK\x03\x04rest")
    File.binwrite(k = File.join(dir, 'b'), "\xFF\xFE\xFF\x0ES\x00k\x00e\x00t\x00c\x00h\x00U\x00p\x00 \x00M".b)
    File.write(h = File.join(dir, 'c'), "  <!DOCTYPE html><html>")
    assert_equal '.zip', SL::LinkImport.sniff(z)
    assert_equal '.skp', SL::LinkImport.sniff(k)
    assert_nil SL::LinkImport.sniff(h)
  end
end

class TestAppSources < Minitest::Test
  def setup
    SL::Paths.reset!
    @data = Dir.mktmpdir('appsrc_')
    ENV['MT_SMART_LIBRARY_DATA'] = @data
    @dl = Dir.mktmpdir('dl_')
    ENV['MT_DOWNLOADS_DIR'] = @dl
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    UI.opened.clear
    UI::HtmlDialog.instances.clear
    @app = SL::App.new
    @got = []
    got = @got
    @app.define_singleton_method(:smart_insert) { |path, name: nil, passwords: []| got << [path, name] }
  end

  def teardown
    ENV.delete('MT_DOWNLOADS_DIR')
    SL::Paths.reset!
  end

  def test_add_website_becomes_real_search_provider
    posts = JSON.generate([{ 'id' => 7, 'title' => { 'rendered' => 'Sofa da hiện đại' }, 'link' => 'https://myskp.vn/sofa-da/', 'featured_media' => 8 }])
    media = JSON.generate([{ 'id' => 8, 'source_url' => 'https://cdn.myskp.vn/sofa.jpg' }, { 'id' => 9, 'source_url' => 'https://evil.com/x.jpg' }])
    @app.instance_variable_set(:@http, SeqHttp.new('robots.txt' => [404, ''], 'wp-json/wp/v2/posts' => [200, posts], 'wp-json/wp/v2/media' => [200, media]))
    @app.src_add('url' => 'https://myskp.vn', 'name' => 'My SKP')
    s = @app.instance_variable_get(:@sources).custom.first
    assert_equal 'wp_rest', s['method']
    prov = @app.instance_variable_get(:@providers).find { |p| p.id == s['id'] }
    assert prov, 'nguồn người dùng trở thành provider tìm kiếm thật'
    st = @app.instance_variable_get(:@settings)
    q = SL::QueryNormalizer.analyze('sofa da')
    sess = SL::SearchManager::Session.new(1, q, [], q.primary_en, SL::Categories.find('all', []), [], 'all', 'all', {}, {}, st, 0, 0, q)
    out = nil
    prov.search(sess, nil) { |r| out = r }
    it = out['items'].first
    assert_equal 'Sofa da hiện đại', it['title']
    assert_equal 'https://cdn.myskp.vn/sofa.jpg', it['thumb'], 'ảnh từ tên miền con của trang được nhận'
    assert it['web_only']
    @app.src_toggle(s['id'], false)
    refute(@app.instance_variable_get(:@providers).any? { |p| p.id == s['id'] }, 'tắt nguồn: không tìm nữa')
    pl = @app.sources_payload
    assert(pl['list'].any? { |x| x['builtin'] && x['id'] == 'sketchfab' })
    assert(pl['list'].any? { |x| x['id'] == s['id'] && x['method_label'] == 'WordPress REST API công khai' })
  end

  def test_facebook_source_is_kept_with_manual_access
    @app.instance_variable_set(:@http, SeqHttp.new({}))
    @app.src_add('url' => 'https://www.facebook.com/groups/thuvien3d')
    s = @app.instance_variable_get(:@sources).custom.first
    assert_equal 'facebook_group', s['type']
    assert_equal 'login', s['status'], 'không bị loại bỏ vì cần đăng nhập'
    assert_match(/Groups API/, s['note'])
    @app.src_open(s['id'])
    assert_equal ['https://www.facebook.com/groups/thuvien3d'], UI.opened
    assert @app.instance_variable_get(:@watcher).active?, 'mở nguồn → tự nhận file vừa tải'
  end

  def test_link_import_direct_and_page
    zip = "PK\x03\x04" + 'x' * 50
    @app.instance_variable_set(:@http, SeqHttp.new('dl=1' => [200, zip], 'page.html' => [200, '<!DOCTYPE html><html></html>']))
    @app.link_import('https://www.dropbox.com/s/abc123/ghe.zip?dl=0')
    assert_equal 1, @got.size
    assert @got[0][0].end_with?('.zip')
    assert_equal zip.b, File.binread(@got[0][0]).b
    @app.link_import('https://files.example.com/page.html')
    assert_equal 1, @got.size, 'trang HTML không bị coi là model'
    @app.link_import('https://www.facebook.com/groups/x/posts/1')
    assert_includes UI.opened, 'https://www.facebook.com/groups/x/posts/1'
  end
end

# Kho dữ liệu tích lũy (SQLite trong tiến trình AI) + 2 làn xử lý — chạy THẬT bằng python + onnxruntime.
class TestCatalog < Minitest::Test
  def setup
    skip 'cần python3 + onnxruntime' unless ort_ok?
    @data = Dir.mktmpdir('cat_')
    @models = File.join(@data, 'm')
    system(PY, File.join(__dir__, 'fixtures', 'make_tiny_clip.py'), @models) or raise 'tiny'
    ENV['MT_AI_PYTHON'] = PY
    ENV['MT_AI_MODELS'] = @models
    @img = File.join(@data, 'img')
    FileUtils.mkdir_p(@img)
    @rt = SL::RuntimeManager.new(http: Object.new, runner: SL::BlenderRunner.new, data_root: @data, code_dir: File.join(SRC, 'mt_smart_library'))
    @rt.cfg['model']['min_score'] = 0.0
  end

  def teardown
    @rt&.stop
    %w[MT_AI_PYTHON MT_AI_MODELS].each { |k| ENV.delete(k) }
  end

  def wait(id_box, secs = 40)
    t0 = Time.now
    until id_box[0] || Time.now - t0 > secs
      @rt.poll
      sleep 0.05
    end
    id_box[0] || flunk('hết giờ')
  end

  def job(type, payload, lane: 'search')
    box = [nil]
    @rt.submit(type, payload, lane: lane) { |r| box[0] = r }
    r = wait(box)
    assert r['ok'], r.inspect
    r['result']
  end

  def test_store_dedupe_search_stats_clear_and_lanes
    red = draw("#{@img}/red.png", [{ 'shape' => 'circle', 'box' => [80, 80, 320, 320], 'color' => 'red' }])
    blue = draw("#{@img}/blue.png", [{ 'shape' => 'rect', 'box' => [20, 150, 380, 250], 'color' => 'blue' }])
    cache = File.join(@rt.work_dir, 'online_thumbs')
    FileUtils.mkdir_p(cache)
    urls = { 'https://media.sketchfab.com/r.png' => red, 'https://sketchup.cgtips.org/r-copy.png' => red, 'https://cdn.polyhaven.com/b.png' => blue }
    urls.each { |u, f| FileUtils.cp(f, File.join(cache, Digest::SHA1.hexdigest(u) + '.img')) }
    items = [
      { 'key' => 'sketchfab:a', 'source' => 'sketchfab', 'title' => 'Round red', 'thumb' => urls.keys[0], 'url' => 'https://sketchfab.com/a' },
      { 'key' => 'cgtips:b', 'source' => 'cgtips', 'title' => 'Round red (đăng lại)', 'thumb' => urls.keys[1], 'url' => 'https://sketchup.cgtips.org/b' },
      { 'key' => 'polyhaven:c', 'source' => 'polyhaven', 'title' => 'Blue bar', 'thumb' => urls.keys[2], 'url' => 'https://polyhaven.com/a/c' }
    ]
    assert_equal 3, job('catalog_upsert', { 'items' => items })['added']
    assert_equal 0, job('catalog_upsert', { 'items' => items })['added'], 'lưu lại không tạo bản mới'
    vq = File.join(@data, 'q.npy')
    job('embed_query', { 'image' => red, 'out_vec' => vq })
    r = job('rank_urls', { 'vec' => vq, 'hosts' => urls.keys.map { |u| URI.parse(u).host }, 'store' => items,
                           'items' => items.map { |i| { 'key' => i['key'], 'url' => i['thumb'] } } })
    assert_equal 1, r['dups'], 'ảnh giống hệt từ nguồn khác → đánh dấu trùng'
    st = job('catalog_stats', {})
    assert_equal 3, st['total']
    assert_equal 3, st['with_vec']
    assert_equal 1, st['dup']
    found = job('catalog_search', { 'vec' => vq, 'k' => 10 })['items']
    assert_equal 'Round red', found.first['title'], 'tìm lại từ kho, không cần mạng'
    assert_equal 2, found.size, 'bản trùng bị ẩn'
    assert(found.all? { |i| i['from_catalog'] && i['vscore'] })
    assert_equal ['polyhaven:c'], job('catalog_search', { 'vec' => vq, 'k' => 10, 'exclude_sources' => ['sketchfab'] })['items'].map { |i| i['key'] }
    chk = job('catalog_check_links', { 'limit' => 10, 'concurrency' => 2 })
    assert_equal 3, chk['checked'] # máy test không có mạng: trạng thái “không xác định”, không xóa dữ liệu
    # Làn lập chỉ mục chạy tiến trình riêng
    lib = File.join(@data, 'lib.json')
    File.write(lib, JSON.generate([]))
    job('index_sync', { 'items_file' => lib, 'limit' => 10 }, lane: 'index')
    assert @rt.worker_alive?('search') && @rt.worker_alive?('index'), 'hai làn xử lý độc lập'
    assert File.directory?(File.join(@rt.work_dir, 'jobs', 'index'))
    cl = job('catalog_clear', {})
    assert cl['cleared']
    assert_equal 0, job('catalog_stats', {})['total']
    assert_empty Dir.glob(File.join(cache, '*.img')), 'xóa cả ảnh xem trước đã lưu'
  end
end
