# frozen_string_literal: true
# V1.0.16 — Tìm model trên website qua công cụ tìm kiếm web.
# Dữ liệu fixtures/web_real/tavily_2026-11-26.json là phản hồi THẬT của Tavily (chế độ không key) ghi lại ngày 26/11/2026
# cho các từ khóa kiểm thử — không phải dữ liệu tự tạo.
require_relative 'test_helper'
require 'tmpdir'

WM = SL::WebModels
QN2 = SL::QueryNormalizer
REAL = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'web_real', 'tavily_2026-11-26.json')))

class TestWebModels < Minitest::Test
  NON_DETAIL = %r{/search|/tag/|/tim-kiem/|/tailieu/search|/3dmodels/(furniture|lighting)/|/collection/|/blog|/chuyen-muc/|\?page=|/den-tha\.html|sketchup-3d-models-3/chairs-24\z}

  def kept(kw)
    q = QN2.analyze(kw)
    REAL.select { |e| e['kw'] == kw }.flat_map do |e|
      site = WM.site(e['site'])
      e['results'].map { |r| WM.normalize(site, r, q) }.compact
    end.uniq { |i| i['uid'] }
  end

  def test_translation_vi_to_en
    {
      'sofa' => 'sofa', 'bàn thờ' => 'altar', 'ghế ăn' => 'dining chair', 'đèn thả' => 'pendant lamp',
      'phào chỉ' => 'moulding', 'vách CNC' => 'cnc panel'
    }.each { |vi, en| assert_equal en, QN2.analyze(vi).primary_en, vi }
  end

  def test_real_results_only_detail_links_and_relevant
    report = {}
    %w[sofa bàn\ thờ ghế\ ăn đèn\ thả].each do |kw|
      items = kept(kw)
      report[kw] = items.group_by { |i| i['site'] }.transform_values(&:size)
      refute_empty items, kw
      items.each do |i|
        refute_match NON_DETAIL, i['url'], "#{kw}: link không phải trang chi tiết #{i['url']}"
        assert i['url'].start_with?('https://'), i['url']
        site = WM.site(i['site'])
        assert WM.detail_link(site, i['url']), i['url']
        assert WM.relevant?(QN2.analyze(kw), "#{i['title']} #{i['url'].tr('/-_', '   ')}"), "#{kw}: #{i['title']}"
      end
      assert_equal items.size, items.map { |i| i['url'] }.uniq.size, "#{kw}: trùng link"
    end
    # Số link chi tiết thật tìm được từ dữ liệu thật (tối thiểu, tránh lệch khi chỉnh lọc).
    assert_operator report['sofa'].values.sum, :>=, 40
    assert_operator report['sofa'].keys.size, :>=, 5 # 3D Warehouse, 3dsky, 3DBox, Sketch Shaper, Tài liệu kiến trúc
    assert_operator report['bàn thờ']['warehouse'].to_i, :>=, 5
    assert_operator report['bàn thờ']['tailieukientruc'].to_i, :>=, 3
    assert_operator report['ghế ăn']['warehouse'].to_i, :>=, 8
    assert_operator report['đèn thả']['tailieukientruc'].to_i, :>=, 4
    File.write(File.join(Dir.tmpdir, 'web_real_report.json'), JSON.pretty_generate(report))
  end

  def test_irrelevant_and_non_detail_removed
    q = QN2.analyze('ghế ăn')
    box = WM.site('3dbox')
    # 3DBox trả cảnh phòng karaoke / thảm cho "dining chair" → phải loại
    raws = REAL.find { |e| e['kw'] == 'ghế ăn' && e['site'] == '3dbox' }['results']
    assert_equal 5, raws.size
    assert_empty(raws.map { |r| WM.normalize(box, r, q) }.compact)
    # trang danh mục / tìm kiếm / tag / trang chủ
    w = WM.site('warehouse')
    assert_nil WM.detail_link(w, 'https://3dwarehouse.sketchup.com/search/models?q=sofa')
    assert_nil WM.detail_link(w, 'https://3dwarehouse.sketchup.com/')
    assert_nil WM.detail_link(w, 'https://3dwarehouse.sketchup.com/collection/u4c1cc1d0-fa5e/Pendant-lights')
    assert_nil WM.detail_link(WM.site('3dsky'), 'https://3dsky.org/3dmodels/lighting/pendant-lights')
    assert_nil WM.detail_link(WM.site('tailieukientruc'), 'https://tailieukientruc.net/den-tha.html')
    assert_nil WM.detail_link(WM.site('tailieukientruc'), 'https://tailieukientruc.net/mat-bang-nha-cap-4.html')
    assert_nil WM.detail_link(WM.site('sketchshaper'), 'https://www.sketchshaper.com/sketchup-3d-models-3/chairs-24')
    assert_nil WM.detail_link(WM.site('sketchupvn'), 'http://sketchup.vn/tag/Cao+Ph%C3%BAc.html')
    # link khác website không được nhận
    assert_nil WM.detail_link(w, 'https://evil.example/model/12345678-aaaa/Sofa')
    # chuẩn hóa link 3D Warehouse bản embed → link chính
    assert_equal 'https://3dwarehouse.sketchup.com/model/ab3eb0a3-af23-4aad-9202-b638e90472a8/Club-Sofa-3-seater-with-cushions',
                 WM.detail_link(w, 'https://embed-3dwarehouse-classic.sketchup.com/model/ab3eb0a3-af23-4aad-9202-b638e90472a8/Club-Sofa-3-seater-with-cushions')[0]
  end

  def test_titles_cleaned
    assert_equal 'Orion sofa 2', WM.clean_title(WM.site('3dsky'), 'Orion sofa 2 - Sofa - 3D model - 3dsky', 'https://3dsky.org/3dmodels/show/orion-sofa-2')
    assert_equal 'Modern Fabric Sofa Set', WM.clean_title(WM.site('3dbox'), 'Modern Fabric Sofa Set | Sofa set | 3D Model | 3Dbox', 'https://3dbox.cc/detail/1')
    assert_equal 'Model sketchup bàn thờ chạm khắc thủ công miễn phí',
                 WM.clean_title(WM.site('tailieukientruc'), '67. Model sketchup bàn thờ chạm khắc thủ công miễn phí - Thư viện kiến trúc', 'https://tailieukientruc.net/x-17664.html')
    assert_equal 'Moosh Dining Chair', WM.clean_title(WM.site('3dsky'), 'Moosh Dining Chair - Chair - 3D model - 3dsky.org', 'https://3dsky.org/3dmodels/show/x')
    assert_equal 'Wood Moulding', WM.clean_title(WM.site('warehouse'), 'Wood Moulding | 3D Warehouse - SketchUp', 'https://3dwarehouse.sketchup.com/model/x/y')
    assert_equal 'Round sofa', WM.clean_title(WM.site('warehouse'), '3D Warehouse', 'https://3dwarehouse.sketchup.com/model/4c3d79ba/Round-sofa')
  end

  def test_one_request_per_site_and_vi_sites_use_vietnamese
    q = QN2.analyze('bàn thờ')
    assert_equal ['altar'], WM.queries_for(WM.site('warehouse'), q, q.primary_en)
    assert_equal ['bàn thờ'], WM.queries_for(WM.site('tailieukientruc'), q, q.primary_en)
    sp = WM.request_spec('serper', WM.site('warehouse'), 'altar', { 'serper' => 'k' }, {})
    assert_equal 'site:3dwarehouse.sketchup.com/model altar', JSON.parse(sp[:body])['q']
    tv = WM.request_spec('tavily', WM.site('3dsky'), 'altar', {}, {})
    assert_equal 'keyless', tv[:headers]['X-Tavily-Access-Mode']
    assert_equal ['3dsky.org'], JSON.parse(tv[:body])['include_domains']
    assert_nil WM.request_spec('serper', WM.site('3dsky'), 'altar', {}, {}) # chưa có key → bỏ qua
    # Google trước, Tavily cuối khi có key Google
    assert_equal %w[serper tavily], WM.providers({ 'order' => %w[tavily serper serpapi brave searxng], 'enabled' => {} }, { 'serper' => 'x' })
    assert_equal %w[tavily], WM.providers({ 'enabled' => {} }, {})
  end

  def test_quota_detection
    assert_raises(WM::QuotaError) { WM.parse_response('tavily', 429, '{"error":{"code":"hourly_cap_reached"}}') }
    assert_raises(WM::QuotaError) { WM.parse_response('serper', 403, '{}') }
    assert_equal 1, WM.parse_response('serper', 200, '{"organic":[{"link":"https://3dsky.org/3dmodels/show/a","title":"A","imageUrl":"https://x/y.jpg"}]}').size
  end

  def test_search_urls_for_direct_search
    assert_equal 'https://3dwarehouse.sketchup.com/search/models?q=b%C3%A0n+th%E1%BB%9D', WM.search_url('warehouse', 'bàn thờ')
    assert_equal 'https://www.sketchshaper.com/sketchup-3d-models-3?search=sofa', WM.search_url('sketchshaper', 'sofa')
    assert_equal 'https://3dsky.org/3dmodels?query=sofa', WM.search_url('3dsky', 'sofa')
    assert WM.search_url('tailieukientruc', 'bàn thờ').start_with?('https://www.google.com/search?q=site%3Atailieukientruc.net+')
    assert WM.search_url('3dbox', 'sofa').include?('site%3A3dbox.cc%2Fdetail')
  end

  def test_robots_and_og_image
    rules = WM.parse_robots("User-agent: GPTBot\nDisallow: /\n\nUser-agent: *\nDisallow: /api/\nDisallow: /*?ref\nAllow: /api/public\n")
    assert WM.robots_allow?(rules, '/3dmodels/show/orion-sofa-2')
    refute WM.robots_allow?(rules, '/api/models')
    assert WM.robots_allow?(rules, '/api/public/x')
    refute WM.robots_allow?(rules, '/a?ref=1')
    assert WM.robots_allow?([], '/x')
    html = '<head><meta property="og:image" content="https://b6.3dsky.org/media/a.jpeg"><meta property="og:title" content="x"></head>'
    assert_equal 'https://b6.3dsky.org/media/a.jpeg', WM.og_image(html)
    assert_nil WM.og_image('<meta property="og:image" content="http://insecure/a.jpg">')
    jpg = "\xFF\xD8\xFF\xE0".b + ('x' * 300)
    assert WM.data_uri(jpg).start_with?('data:image/jpeg;base64,')
    assert_nil WM.data_uri('<html>not image</html>' * 20)
  end
end

# Luồng đầy đủ: song song nhiều website, Serper hết hạn mức → tự chuyển Tavily, đổ kết quả dần, báo trạng thái từng website.
class TestWebModelsProvider < Minitest::Test
  def setup
    ENV['MT_TEST_NO_DELAY'] = '1'
    @tav_hits = []
    @tav = MockHTTP.new do |req|
      b = JSON.parse(req[:body])
      @tav_hits << b
      host = b['include_domains'][0]
      site = WM::SITES.find { |s| s['host'].sub(/\Awww\./, '') == host }
      q = b['query'].sub(/ (3d model|sketchup)\z/, '')
      e = REAL.find { |x| x['site'] == site['id'] && x['q'] == q }
      e ? [200, {}, JSON.generate('results' => e['results'].map { |r| r.merge('content' => r['content']) })] : [200, {}, '{"results":[]}']
    end
    @ser = MockHTTP.new { |_req| [429, {}, '{"message":"Too many requests"}'] }
    ENV['MT_TEST_TAVILY_BASE'] = @tav.url('')
    ENV['MT_TEST_SERPER_BASE'] = @ser.url('')
    @http = SL::HttpClient.new
    @settings = SL::Settings.new(File.join(Dir.mktmpdir, 's.json'))
    @prov = SL::Providers::WebModelsProvider.new(@http, SL::ResultCache.new, -> { { 'serper' => 'test-key' } })
    @prov.max_thumbs = 0
    @sites = []
    @prov.on_sites = ->(pl) { @sites << pl }
    @events = []
    @mgr = SL::SearchManager.new(providers: [@prov], settings: @settings, emit: ->(t, p) { @events << [t, p] })
  end

  def teardown
    %w[MT_TEST_NO_DELAY MT_TEST_TAVILY_BASE MT_TEST_SERPER_BASE].each { |k| ENV.delete(k) }
    @tav.close
    @ser.close
  end

  def last_update
    @events.reverse.find { |t, _| t == 'sr_update' }&.last
  end

  def test_parallel_sites_fallback_and_results
    @mgr.start('sid' => 3, 'q' => 'bàn thờ', 'category' => 'all')
    wait_http(@http, 20) { (u = last_update) && !u['loading'] && u['items'].any? }
    u = last_update
    items = u['items']
    assert(items.all? { |i| i['web_model'] && i['url'].start_with?('https://') && i['source_label'] })
    by = items.group_by { |i| i['site'] }
    assert_operator by['warehouse'].to_a.size, :>=, 5
    assert_operator by['tailieukientruc'].to_a.size, :>=, 3
    assert_equal items.size, items.map { |i| i['url'] }.uniq.size
    # 6 website gọi Serper trước (429) rồi Tavily — mỗi website đúng 1 truy vấn Tavily
    assert_equal 6, @ser.requests.size
    assert_equal 6, @tav_hits.size
    assert_equal 'bàn thờ sketchup', @tav_hits.find { |b| b['include_domains'] == ['tailieukientruc.net'] }['query']
    fin = @sites.last['sites']
    assert(fin.none? { |s| s['state'] == 'loading' })
    assert(fin.all? { |s| s['search_url'].to_s.start_with?('https://') })
    assert_equal 'done', fin.find { |s| s['id'] == 'warehouse' }['state']
    assert_equal 'empty', fin.find { |s| s['id'] == 'sketchshaper' }['state'] # không có link chi tiết → nút tìm trực tiếp
    assert_equal 'web', SL::ResultRanker.apply_filter(items, 'web').first['source']
    # Lần tìm lại cùng từ khóa: dùng cache, không gọi thêm API
    @mgr.start('sid' => 4, 'q' => 'bàn thờ', 'category' => 'all')
    wait_http(@http, 10) { (u2 = last_update) && u2['sid'] == 4 && !u2['loading'] }
    assert_equal 6, @tav_hits.size
  end

  def test_not_applicable_without_typed_query_or_disabled
    @mgr.start('sid' => 1, 'q' => '', 'category' => 'all')
    assert_empty @sites
    @settings['sources']['web_models'] = false
    @mgr.start('sid' => 2, 'q' => 'sofa', 'category' => 'all')
    assert_empty @sites
  end

  # Có key Serper: Google site: cho kết quả; 3D Warehouse lấy ảnh qua Serper Images (gắn ảnh + bổ sung model có ảnh); ảnh tải về thành data URI.
  def test_serper_google_and_warehouse_images
    jpg = "\xFF\xD8\xFF\xE0".b + ('j' * 400)
    img = MockHTTP.new { |_r| [200, { 'Content-Type' => 'image/jpeg' }, jpg] }
    ser = MockHTTP.new do |req|
      b = JSON.parse(req[:body])
      if req[:path] == '/images'
        [200, {}, JSON.generate('images' => [
          { 'title' => 'Muuto Sofa OUTLINE', 'link' => 'https://3dwarehouse.sketchup.com/model/bdf6f689-16ab-49b3-b11d-84eced1355a9/Muuto-Sofa-OUTLINE-3seater', 'imageUrl' => img.url('/a.jpg').sub('http:', 'https:') },
          { 'title' => 'Fabric Sofa Couch', 'link' => 'https://3dwarehouse.sketchup.com/model/c1c9ebbb-4137-44f4-b3da-79e3bdea9ee2/Fabric-Sofa-Couch?hl=pt-BR', 'imageUrl' => 'https://127.0.0.1:1/b.jpg' },
          { 'title' => 'Office chair', 'link' => 'https://3dwarehouse.sketchup.com/model/aaaaaaaa-1111/Office-Chair', 'imageUrl' => 'https://127.0.0.1:1/c.jpg' }])]
      else
        site = b['q'][/site:(\S+)/, 1]
        if site.start_with?('3dwarehouse')
          [200, {}, JSON.generate('organic' => [
            { 'link' => 'https://3dwarehouse.sketchup.com/model/bdf6f689-16ab-49b3-b11d-84eced1355a9/Muuto-Sofa-OUTLINE-3seater', 'title' => 'Muuto Sofa | OUTLINE 3_seater - 3D Warehouse' },
            { 'link' => 'https://3dwarehouse.sketchup.com/search/models?q=sofa', 'title' => 'sofa - Search - 3D Warehouse' }])]
        else
          [200, {}, '{"organic":[]}']
        end
      end
    end
    ENV['MT_TEST_SERPER_BASE'] = ser.url('')
    prov = SL::Providers::WebModelsProvider.new(@http, SL::ResultCache.new, -> { { 'serper' => 'k' } })
    # ảnh mock chạy http nội bộ: cho phép http cho đúng host kiểm thử
    def prov.fetch_image(run, it, url)
      super(run, it, url.sub('https://127.0.0.1', 'http://127.0.0.1'))
    end
    mgr = SL::SearchManager.new(providers: [prov], settings: @settings, emit: ->(t, p) { @events << [t, p] })
    mgr.start('sid' => 7, 'q' => 'sofa', 'category' => 'all')
    wait_http(@http, 20) { (u = last_update) && u['sid'] == 7 && !u['loading'] && u['items'].any? { |i| i['thumb'] } }
    items = last_update['items']
    titles = items.map { |i| i['title'] }
    assert_includes titles, 'Muuto Sofa | OUTLINE 3_seater'
    assert_includes titles, 'Fabric Sofa Couch' # bổ sung từ Serper Images
    refute(titles.any? { |t| t =~ /Office chair/i }) # không liên quan → loại
    refute(items.any? { |i| i['url'].include?('/search/') })
    muuto = items.find { |i| i['title'].start_with?('Muuto') }
    assert muuto['thumb'].to_s.start_with?('data:image/jpeg;base64,')
    assert_equal 'https://3dwarehouse.sketchup.com/model/c1c9ebbb-4137-44f4-b3da-79e3bdea9ee2/Fabric-Sofa-Couch',
                 items.find { |i| i['title'] == 'Fabric Sofa Couch' }['url']
    assert_equal(1, ser.requests.count { |r| r[:path] == '/images' })
    assert(ser.requests.select { |r| r[:path] == '/search' }.all? { |r| JSON.parse(r[:body])['gl'].nil? })
  ensure
    img&.close
    ser&.close
  end

end
