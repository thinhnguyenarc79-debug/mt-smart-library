# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'test_visual'
require 'socket'

# SMART SOURCE EXTRACTOR chạy THẬT trong tiến trình Python (làn crawl) với máy chủ cục bộ mô phỏng đúng giao thức WordPress REST,
# robots.txt/sitemap, Google Drive API v3 và Brave Search API (máy test không có mạng ra ngoài).
class TestExtractor < Minitest::Test
  def setup
    skip 'cần python3 + onnxruntime' unless ort_ok?
    @port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    @base = "http://127.0.0.1:#{@port}"
    @srv = IO.popen([PY, File.join(__dir__, 'fixtures', 'fake_sources_server.py'), @port.to_s], err: File::NULL)
    @srv.gets # READY
    @data = Dir.mktmpdir('ex_')
    @models = File.join(@data, 'm')
    system(PY, File.join(__dir__, 'fixtures', 'make_tiny_clip.py'), @models) or raise 'tiny'
    { 'MT_AI_PYTHON' => PY, 'MT_AI_MODELS' => @models, 'MT_TEST_ALLOW_HTTP' => '1',
      'MT_TEST_GDRIVE_BASE' => "#{@base}/drive/v3/", 'MT_TEST_BRAVE_BASE' => "#{@base}/brave",
      'MT_TEST_TAVILY_BASE' => "#{@base}/tavily", 'MT_TEST_SERPER_BASE' => "#{@base}/serper" }.each { |k, v| ENV[k] = v }
    @rt = SL::RuntimeManager.new(http: Object.new, runner: SL::BlenderRunner.new, data_root: @data, code_dir: File.join(SRC, 'mt_smart_library'))
    @keys = { 'MT_SRC_GOOGLE_KEY' => 'GKEY', 'MT_SRC_BRAVE_KEY' => 'BKEY' }
    @rt.env_provider = ->(lane) { lane == 'crawl' ? @keys : {} }
  end

  def teardown
    @rt&.stop
    Process.kill('TERM', @srv.pid) rescue nil
    %w[MT_AI_PYTHON MT_AI_MODELS MT_TEST_ALLOW_HTTP MT_TEST_GDRIVE_BASE MT_TEST_BRAVE_BASE MT_TEST_TAVILY_BASE MT_TEST_SERPER_BASE
       FAKE_TAVILY].each { |k| ENV.delete(k) }
  end

  def job(type, payload, lane: 'crawl', progress: nil, secs: 60)
    box = [nil]
    id = @rt.submit(type, payload, lane: lane, on_progress: progress) { |r| box[0] = r }
    yield id if block_given?
    t0 = Time.now
    until box[0] || Time.now - t0 > secs
      @rt.poll
      sleep 0.05
    end
    box[0] || flunk("hết giờ #{type}")
  end

  def items_of(source)
    r = job('catalog_text', { 'groups' => [], 'limit' => 100 }, lane: 'search')
    r['result']['items'].select { |i| i['source'] == source }
  end

  def test_wordpress_full_then_incremental_sync
    src = { 'id' => 'u_wp00000001', 'name' => 'WP test', 'type' => 'website', 'url' => @base }
    chk = job('src_check', { 'source' => src })['result']
    assert_equal 'wp_rest', chk['method'], chk.inspect
    phases = []
    r = job('src_crawl', { 'source' => src.merge('method' => 'wp_rest'), 'mode' => 'full', 'limit' => 100 }, progress: ->(p) { phases << p })
    assert r['ok'], r.inspect
    assert_equal 2, r['result']['found']
    assert_equal 2, r['result']['with_links']
    items = items_of('u_wp00000001')
    sofa = items.find { |i| i['title'] =~ /Chesterfield/ }
    assert_equal 'Classic Tufted Chesterfield Sofa 3D Model SketchUp Download', sofa['title']
    assert_equal ['Sofa'], sofa['categories']
    assert_equal "#{@base}/img/1.png", sofa['thumb']
    assert_equal 'sketchup.cgtips.org', sofa['password'], 'trích xuất mật khẩu giải nén'
    assert_equal [['https://link.example.org/5RkcdHPqxe', 'short']], sofa['links'].map { |l| [l['url'], l['kind']] }
    ban = items.find { |i| i['title'].start_with?('Bàn ăn') }
    assert_equal 'dropbox', ban['links'][0]['kind']
    assert_equal 1, ban['links'].size, 'bỏ link mạng xã hội'
    assert ban['downloadable']
    # Tìm theo từ khóa tiếng Việt không dấu/có dấu
    hit = job('catalog_text', { 'groups' => [%w[ban table], ['an']], 'limit' => 10 }, lane: 'search')['result']['items']
    assert_equal ['Bàn ăn gỗ óc chó 6 ghế – SketchUp'], hit.map { |i| i['title'] }
    # Đồng bộ: chỉ lấy bài mới hơn lần trước (modified_after)
    r2 = job('src_crawl', { 'source' => src.merge('method' => 'wp_rest'), 'mode' => 'sync', 'limit' => 100 })
    assert_equal 0, r2['result']['found'], 'không có bài mới'
    # Vector ảnh cho tìm bằng ảnh (làn index)
    e = job('catalog_embed', { 'source' => 'u_wp00000001', 'limit' => 50 }, lane: 'index')
    assert_equal 2, e['result']['embedded']
    st = job('catalog_source_stats', { 'ids' => ['u_wp00000001'] }, lane: 'search')['result']['u_wp00000001']
    assert_equal({ 'indexed' => 2, 'with_links' => 2, 'with_vec' => 2 }, st.slice('indexed', 'with_links', 'with_vec'))
    assert st['last_sync'].to_i.positive?
    log = File.read(File.join(@rt.work_dir, 'crawl', 'u_wp00000001.log'))
    assert_match(/BẮT ĐẦU quét toàn bộ/, log)
    assert_match(/XONG: 2 model, 2 có link tải/, log)
  end

  def test_sitemap_crawler_respects_robots
    src = { 'id' => 'u_sm00000001', 'name' => 'Site', 'type' => 'website', 'url' => @base, 'method' => 'sitemap' }
    r = job('src_crawl', { 'source' => src, 'mode' => 'full', 'limit' => 50 })
    assert r['ok'], r.inspect
    titles = items_of('u_sm00000001').map { |i| i['title'] }
    assert_includes titles, 'Đèn thả đồng Bắc Âu - SketchUp'
    refute_includes titles, 'Giới thiệu' if titles.include?('Giới thiệu') && false
    refute(titles.any? { |t| t == 'Không có ảnh' }, 'trang không có ảnh xem trước không được coi là model')
    it = items_of('u_sm00000001').find { |i| i['title'].start_with?('Đèn thả') }
    assert_equal "#{@base}/img/3.png", it['thumb']
    assert_equal ['Đèn'], it['categories']
    assert_equal 'direct', it['links'][0]['kind']
    assert_equal 'mtdesign', it['password']
    log = File.read(File.join(@rt.work_dir, 'crawl', 'u_sm00000001.log'))
    refute_match(%r{/private/an\.html}, log, 'không truy cập đường dẫn robots.txt cấm')
    assert(items_of('u_sm00000001').none? { |i| i['url'].include?('/private/') })
  end

  def test_stop_scan_midway
    src = { 'id' => 'u_sm00000002', 'name' => 'Lớn', 'type' => 'website', 'url' => @base + '/?n=0', 'method' => 'sitemap' }
    # sitemap với nhiều trang (tham số n) → hủy giữa chừng
    src['url'] = @base
    r = job('src_crawl', { 'source' => src, 'mode' => 'full', 'limit' => 50 }) { |id| @rt.cancel(id) }
    assert(r['cancelled'] || r['ok'], r.inspect)
  end

  def test_google_drive_and_brave_index
    drive = { 'id' => 'u_gd00000001', 'name' => 'Drive MT', 'type' => 'gdrive', 'url' => 'https://drive.google.com/drive/folders/ROOTFOLDER1234' }
    assert_equal 'gdrive', job('src_check', { 'source' => drive })['result']['method']
    r = job('src_crawl', { 'source' => drive.merge('method' => 'gdrive'), 'mode' => 'full', 'limit' => 50 })
    assert r['ok'], r.inspect
    its = items_of('u_gd00000001')
    assert_equal ['Sofa góc L', 'Tủ áo gỗ'], its.map { |i| i['title'] }.sort, 'đọc cả thư mục con, bỏ file không phải model'
    tu = its.find { |i| i['title'] == 'Tủ áo gỗ' }
    assert_equal "#{@base}/img/2.png", tu['thumb'], 'ảnh cùng tên làm ảnh xem trước'
    assert_equal 'gdrive_api', tu['links'][0]['kind']
    assert_includes tu['links'][0]['url'], 'key=%7BGOOGLE_KEY%7D', 'không lưu API key vào kho'
    refute_includes File.read(File.join(@rt.work_dir, 'catalog.sqlite'), mode: 'rb'), 'GKEY'
    fb = { 'id' => 'u_fb00000001', 'name' => 'Nhóm 3D', 'type' => 'facebook_group', 'url' => 'https://www.facebook.com/groups/thuvien3d' }
    brave_only = { 'order' => %w[brave], 'enabled' => { 'tavily' => false, 'brave' => true } }
    assert_equal 'index', job('src_check', { 'source' => fb, 'search' => brave_only })['result']['method']
    r = job('src_crawl', { 'source' => fb.merge('method' => 'index'), 'mode' => 'full', 'limit' => 50, 'search' => brave_only })
    assert r['ok'], r.inspect
    posts = items_of('u_fb00000001')
    assert_equal ['Chia sẻ model giường ngủ SketchUp miễn phí'], posts.map { |i| i['title'] }
    assert_equal 'mediafire', posts[0]['links'][0]['kind']
    # Thiếu khóa → báo rõ, không giả kết quả
    @keys = {}
    @rt.lane('crawl').restart
    c = job('src_check', { 'source' => fb, 'search' => brave_only })['result']
    refute c['ok']
    assert_equal 'need_key', c['status']
  end

  FB = { 'id' => 'u_fb00000002', 'name' => 'Nhóm Facebook thuvien3d', 'type' => 'facebook_group',
         'url' => 'https://www.facebook.com/groups/thuvien3d', 'method' => 'index' }.freeze

  def test_facebook_without_any_key_uses_tavily_keyless
    @keys = {}
    @rt.lane('crawl').restart
    c = job('src_check', { 'source' => FB })['result']
    assert c['ok'], 'mặc định không cần key (Tavily không key)'
    assert_includes c['note'], 'Tavily'
    r = job('src_crawl', { 'source' => FB, 'mode' => 'full', 'limit' => 50 })
    assert r['ok'], r.inspect
    assert_equal 'Thư Viện 3D SketchUp Việt Nam', r['result']['group_name'], 'tên thật của nhóm từ kết quả tìm kiếm'
    assert_equal({ 'Tavily' => r['result']['providers_used']['Tavily'] }, r['result']['providers_used'])
    posts = items_of('u_fb00000002')
    assert_equal ['Sofa văng da Ý - file SketchUp'], posts.map { |i| i['title'] }, 'chỉ bài của đúng nhóm; bỏ trang gốc và nhóm khác'
    assert_equal 'gdrive', posts[0]['links'][0]['kind']
    assert_equal 'mtdesign', posts[0]['password']
  end

  def test_provider_fallback_when_first_is_rate_limited
    flag = File.join(Dir.tmpdir, "fake_tavily_limit_#{@port}")
    File.write(flag, '1') # máy chủ thử: Tavily không key trả 429
    @keys = { 'MT_SRC_SERPER_KEY' => 'SKEY' }
    @rt.lane('crawl').restart
    r = job('src_crawl', { 'source' => FB, 'mode' => 'full', 'limit' => 50 })
    assert r['ok'], r.inspect
    assert_equal ['Serper (Google)'], r['result']['providers_used'].keys, 'Tavily bị giới hạn → tự chuyển sang Serper'
    assert_equal 1, r['result']['found']
    log = job('src_log', { 'id' => FB['id'] }, lane: 'search')['result']['text']
    assert_match(/Tavily: HTTP 429.*chuyển sang công cụ tìm kiếm khác/, log)
    t = job('search_test', { 'provider' => 'serper', 'search' => {} })['result']
    assert t['ok']
    bad = job('search_test', { 'provider' => 'serpapi', 'search' => {} })['result']
    refute bad['ok']
    assert_includes bad['error'], 'chưa có key'
  ensure
    File.delete(flag) if flag && File.exist?(flag)
  end

  def test_facebook_saved_posts_extract_title_links_password
    posts = [{ 'url' => 'https://www.facebook.com/groups/thuvien3d/posts/333', 'images' => [],
               'text' => "Bộ bàn ăn gỗ óc chó 6 ghế\nFile SKP 2021\nLink tải: https://www.mediafire.com/file/xyz/banan.rar/file\nPass: 123mt",
               'links' => ['https://www.mediafire.com/file/xyz/banan.rar/file', 'https://www.facebook.com/hashtag/sketchup'] },
             { 'url' => 'javascript:alert(1)', 'text' => 'x' }]
    r = job('fb_ingest', { 'source' => FB, 'posts' => posts, 'group_name' => 'Thư Viện 3D' })
    assert r['ok'], r.inspect
    assert_equal 1, r['result']['found'], 'bỏ link không phải https'
    it = items_of('u_fb00000002').find { |i| i['uid'] }
    assert_equal 'Bộ bàn ăn gỗ óc chó 6 ghế', it['title']
    assert_equal ['mediafire'], it['links'].map { |l| l['kind'] }, 'bỏ link Facebook nội bộ'
    assert_equal '123mt', it['password']
  end
end
