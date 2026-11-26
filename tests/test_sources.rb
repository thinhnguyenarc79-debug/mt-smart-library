# frozen_string_literal: true
require_relative 'test_helper'
QN = SL::QueryNormalizer unless defined?(QN)

# Dữ liệu mẫu theo đúng cấu trúc JSON thật đã kiểm tra trên sketchup.cgtips.org / thuviensketchup.vn (25/11/2026).
CG_POSTS = JSON.generate([
  { 'id' => 1_077_111, 'title' => { 'rendered' => '21805. Classic Tufted Chesterfield Sofa 3D Model SketchUp Download' },
    'link' => 'https://sketchup.cgtips.org/21805-classic-tufted-chesterfield-sofa-3d-model-sketchup-download/', 'featured_media' => 1_077_112 },
  { 'id' => 1_080_080, 'title' => { 'rendered' => '21860. Free Sketchup Living Room &#8211; Kitchen Interior Model Download by Tran Nam' },
    'link' => 'https://sketchup.cgtips.org/21860-free-sketchup-living-room-kitchen-interior-model-download-by-tran-nam/', 'featured_media' => 1_080_082 },
  { 'id' => 5, 'title' => { 'rendered' => 'Evil' }, 'link' => 'https://evil.example.com/x', 'featured_media' => 0 }
])
CG_MEDIA = JSON.generate([
  { 'id' => 1_077_112, 'source_url' => 'https://sketchup.cgtips.org/wp-content/uploads/2026/11/21805-2.jpg',
    'media_details' => { 'sizes' => { 'medium' => { 'source_url' => 'https://sketchup.cgtips.org/wp-content/uploads/2026/11/21805-2-370x235.jpg' },
                                      'large' => { 'source_url' => 'https://sketchup.cgtips.org/wp-content/uploads/2026/11/21805-2-1500x953.jpg' } } } },
  { 'id' => 1_080_082, 'source_url' => 'https://evil.example.com/x.jpg', 'media_details' => {} }
])
TV_POSTS = JSON.generate([
  { 'id' => 15_189, 'title' => { 'rendered' => 'SOFA TÂN CỔ ĐIỂN (40 Model) &#8211; SketchUp' }, 'link' => 'https://thuviensketchup.vn/sofa-tan-co-dien-model-sketchup/', 'featured_media' => 0 },
  { 'id' => 16_000, 'title' => { 'rendered' => 'GIƯỜNG NGỦ HIỆN ĐẠI (30 Model)' }, 'link' => 'https://thuviensketchup.vn/giuong-ngu/', 'featured_media' => 0 }
])

class MultiHttp
  attr_reader :urls
  attr_accessor :fail_code
  def initialize(map); @map = map; @urls = []; @fail_code = nil; end
  def request(opts, &cb)
    @urls << opts[:url]
    if @fail_code
      return cb.call(SL::HttpClient::Result.new(false, @fail_code, '', {}, @fail_code.zero? ? :network : nil, 'x', nil, opts[:url]))
    end
    body = @map.find { |k, _| opts[:url].include?(k) }&.last
    cb.call(SL::HttpClient::Result.new(!body.nil?, body ? 200 : 404, body.to_s, {}, nil, nil, nil, opts[:url]))
    1
  end
  def cancel(_); end
end

class TestWpSources < Minitest::Test
  def session(text, st)
    q = QN.analyze(text)
    SL::SearchManager::Session.new(1, q, [], q.primary_en, SL::Categories.find('all', []), [], 'all', 'all', {}, {}, st, 0, 0,
                                   QN.analyze(q.primary_en.to_s))
  end

  def settings
    SL::Settings.new(File.join(Dir.mktmpdir, 's.json'))
  end

  def test_urls_use_core_wordpress_rest_api
    u = SL::WpSources.search_url('cgtips', 'sofa & chair', 2)
    assert_match %r{\Ahttps://sketchup\.cgtips\.org/wp-json/wp/v2/posts\?search=sofa\+%26\+chair&per_page=20&page=2&_fields=}, u
    m = SL::WpSources.media_url('sketchupfree', [3, 3, 'x', 9])
    assert_includes m, 'https://sketchupfree.com/wp-json/wp/v2/media?include=3%2C9'
    assert_raises(RuntimeError) { SL::WpSources.site('evil') }
  end

  def test_parse_posts_and_media_safety
    posts = SL::WpSources.parse_posts('cgtips', CG_POSTS)
    assert_equal 2, posts.size, 'bỏ link ngoài trang'
    assert_equal 'Classic Tufted Chesterfield Sofa 3D Model SketchUp Download', posts[0]['title'], 'bỏ số thứ tự đầu tiêu đề'
    assert_equal 'Free Sketchup Living Room – Kitchen Interior Model Download by Tran Nam', posts[1]['title'], 'giải mã HTML entity'
    media = SL::WpSources.parse_media('cgtips', CG_MEDIA)
    assert_match(/370x235/, media[1_077_112][0])
    assert_match(/1500x953/, media[1_077_112][1])
    assert_nil media[1_080_082], 'ảnh ngoài host bị bỏ'
    assert_raises(RuntimeError) { SL::WpSources.parse_posts('cgtips', '{"code":"rest_no_route"}') }
  end

  def test_provider_english_site
    http = MultiHttp.new('/wp/v2/posts' => CG_POSTS, '/wp/v2/media' => CG_MEDIA)
    p = SL::Providers::WpProvider.new('cgtips', http, SL::ResultCache.new)
    st = settings
    s = session('ghế sofa', st)
    assert p.applicable?(s, st)
    out = nil
    p.search(s, nil) { |r| out = r }
    assert_includes http.urls[0], 'search=sofa', 'tìm bằng từ khóa đã dịch'
    it = out['items'].find { |i| i['title'].include?('Chesterfield') }
    assert it['web_only'] && !it['insertable'] && !it['downloadable'] && it['free']
    assert_equal 'skp', it['format']
    assert_equal 'SketchUp CGTips', it['source_label']
    assert_match(/370x235/, it['thumb'])
    assert_nil out['next'], 'ít hơn 1 trang → hết'
    n = http.urls.size
    p.search(s, nil) { |r| out = r }
    assert_equal n, http.urls.size, 'cache kết quả'
  end

  def test_provider_vietnamese_site_relevance_and_errors
    http = MultiHttp.new('/wp/v2/posts' => TV_POSTS)
    p = SL::Providers::WpProvider.new('thuviensketchup', http, SL::ResultCache.new)
    st = settings
    s = session('giường ngủ', st)
    out = nil
    p.search(s, nil) { |r| out = r }
    assert_includes URI.decode_www_form_component(http.urls[0]), 'search=giường ngủ', 'trang tiếng Việt: tìm bằng từ khóa gốc'
    assert_equal 1, http.urls.size, 'không có ảnh → không gọi media'
    rel = out['items'].select { |i| SL::ResultRanker.relevant_online?(i, p.relevance_query(s), []) }
    assert_equal ['GIƯỜNG NGỦ HIỆN ĐẠI (30 Model)'], rel.map { |i| i['title'] }
    refute out['items'][0]['free'], 'gói trả phí'
    # Lỗi mạng: trả lỗi gọn, không ném ngoại lệ
    http.fail_code = 0
    p2 = SL::Providers::WpProvider.new('thuviensketchup', http, SL::ResultCache.new)
    p2.search(session('bàn', st), nil) { |r| out = r }
    assert out['error'] && out['offline']
    http.fail_code = 400
    p2.search(session('bàn', st), 3) { |r| out = r }
    assert_nil out['error'], 'quá trang cuối (400) = hết kết quả'
    st.apply_ui('sources' => { 'thuviensketchup' => false })
    refute p.applicable?(s, st)
  end

  def test_download_watcher
    dir = Dir.mktmpdir('dl_')
    File.write(File.join(dir, 'old.skp'), 'old')
    w = SL::DownloadWatcher.new(dir)
    assert w.start(source: 'SketchUp CGTips', title: 'Sofa', passwords: ['pw'])
    t = Time.now.to_f
    assert_nil w.poll(t + 3)
    File.write(File.join(dir, 'sofa.zip.crdownload'), 'x' * 10)
    File.write(File.join(dir, 'notes.txt'), 'x')
    assert_nil w.poll(t + 6), 'bỏ file đang tải dở và file không phải model'
    File.write(File.join(dir, 'sofa.zip'), 'x' * 10)
    assert_nil w.poll(t + 9), 'chờ dung lượng ổn định'
    f = w.poll(t + 12)
    assert_equal File.join(dir, 'sofa.zip'), f[:path]
    assert_equal ['pw'], f[:passwords]
    refute w.active?, 'nhận 1 file rồi dừng'
    refute SL::DownloadWatcher.new(File.join(dir, 'missing')).start(source: 'x', title: 'y')
  end

  def test_extract_password_zip_from_source
    src = Dir.mktmpdir('zc_')
    FileUtils.mkdir_p(File.join(src, 'm', 'textures'))
    File.binwrite(File.join(src, 'm', 'textures', 'wood.jpg'), Random.new(1).bytes(50_000))
    File.write(File.join(src, 'm', 'sofa.skp'), 'skp-data')
    zip = File.join(src, 'enc.zip')
    Dir.chdir(src) { system('zip', '-q', '-P', 'sketchup.cgtips.org', '-r', zip, 'm') or skip('thiếu lệnh zip') }
    out = Dir.mktmpdir('out_')
    SL::ImportManager.extract_zip(zip, out, passwords: ['sketchup.cgtips.org'])
    assert_equal 'skp-data', File.read(File.join(out, 'm', 'sofa.skp'))
    assert_equal File.binread(File.join(src, 'm', 'textures', 'wood.jpg')), File.binread(File.join(out, 'm', 'textures', 'wood.jpg'))
    assert_raises(SL::ZipReader::Error) { SL::ImportManager.extract_zip(zip, Dir.mktmpdir, passwords: []) }
    e = assert_raises(SL::ZipReader::Error) { SL::ImportManager.extract_zip(zip, Dir.mktmpdir, passwords: ['sai']) }
    assert_match(/mật khẩu/, e.message)
    assert_raises(SL::ZipReader::Error) { SL::ZipReader.new(zip) } # gói cập nhật: vẫn chặn file mã hóa
  end

  def test_account_statuses
    l = SL::AccountManager.list('sketchfab_token' => false, 'sketchfab_expired' => false)
    by = l.map { |a| [a['id'], a['status']] }.to_h
    assert_equal 'not_logged_in', by['sketchfab']
    assert_equal 'no_login', by['polyhaven']
    assert_equal 'no_login', by['cgtips']
    assert_equal 'need_api', by['cgtrader']
    assert_equal 'web_search', by['warehouse'] # V1.0.16: tìm qua công cụ tìm kiếm web
    assert_equal 'web_search', by['sketchupvn']
    assert_equal 12, l.size
    assert_equal 'connected', SL::AccountManager.list('sketchfab_token' => true)[0]['status']
    ex = SL::AccountManager.list('sketchfab_token' => true, 'sketchfab_expired' => true)[0]
    assert_equal 'expired', ex['status']
    assert_includes ex['actions'], 'reconnect'
    assert_equal 'https://www.cgtrader.com/developers', SL::AccountManager.url_for('cgtrader', 'login')
    assert_includes SL::App::ALLOWED_OPEN_HOSTS, 'sketchup.cgtips.org'
  end

  def test_app_web_item_watch_and_insert
    SL::Paths.reset!
    data = Dir.mktmpdir('appdata_')
    ENV['MT_SMART_LIBRARY_DATA'] = data
    dl = Dir.mktmpdir('dl_')
    ENV['MT_DOWNLOADS_DIR'] = dl
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    UI.opened.clear
    app = SL::App.new
    got = []
    app.define_singleton_method(:smart_insert) { |path, name: nil, passwords: []| got << [path, name, passwords] }
    it = { 'source' => 'cgtips', 'source_label' => 'SketchUp CGTips', 'title' => 'Chesterfield Sofa', 'web_only' => true,
           'url' => 'https://sketchup.cgtips.org/21805-classic/' }
    app.insert_web(it)
    assert_equal ['https://sketchup.cgtips.org/21805-classic/'], UI.opened.last(1)
    File.write(File.join(dl, 'chesterfield.zip'), 'z' * 20)
    w = app.instance_variable_get(:@watcher)
    t = Time.now.to_f
    w.poll(t + 5)
    f = w.poll(t + 10)
    app.instance_variable_set(:@found, f)
    app.insert_found
    assert_equal [[File.join(dl, 'chesterfield.zip'), 'Chesterfield Sofa', ['sketchup.cgtips.org']]], got
    UI.opened.clear
    app.insert_web(it.merge('url' => 'https://evil.example.com/'))
    assert_empty UI.opened, 'không mở link ngoài trang nguồn'
  ensure
    ENV.delete('MT_DOWNLOADS_DIR')
    SL::Paths.reset!
  end
end
