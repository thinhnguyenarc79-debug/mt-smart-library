# frozen_string_literal: true
require_relative 'test_helper'

class TestUtil < Minitest::Test
  U = SL::Util
  def test_fold_vietnamese
    assert_equal 'ghe sofa doi', U.fold('Ghế Sofa Đôi')
    assert_equal 'ban an go 6 cho', U.fold('Bàn_ăn-gỗ 6chỗ')
    assert_equal 'modern sofa 01', U.fold('ModernSofa01')
    nfd = "Gh\u0065\u0302\u0301"
    assert_equal 'ghe', U.fold(nfd)
  end

  def test_norm_path_and_roots
    assert_equal 'C:/Thu vien/SKP', U.norm_path('C:\\Thu vien\\SKP\\')
    assert_equal '//server/share/3D', U.norm_path('\\\\server\\share\\3D')
    assert_equal 'D:/', U.norm_path('D:\\')
    assert U.under_root?('//server/share/3D/a.skp', '//server/share/3D')
    refute U.under_root?('/a/bc/x.skp', '/a/b')
  end

  def test_file_url_unicode
    assert_equal 'file:///C:/Th%C6%B0%20vi%E1%BB%87n', U.file_url('C:\\Thư viện')
    assert_equal 'file://server/share', U.file_url('\\\\server\\share')
  end

  def test_utf8_invalid
    s = "abc\xFF".b
    assert U.utf8(s).valid_encoding?
  end

  def test_atomic_write
    d = Dir.mktmpdir
    f = File.join(d, 'x.json')
    U.atomic_write(f, '{"a":1}')
    U.atomic_write(f, '{"a":2}')
    assert_equal '{"a":2}', File.read(f)
    assert_equal '{"a":1}', File.read(f + '.bak')
    assert_empty Dir.glob(File.join(d, '*.tmp*'))
  end
end

class TestVersionUtil < Minitest::Test
  V = SL::VersionUtil
  def test_compare
    assert V.newer?('1.0.1', '1.0.0')
    assert V.newer?('1.10.0', '1.9.9')
    assert V.newer?('1.0.0', '1.0.0-beta.2')
    assert_equal 0, V.compare('1.0', '1.0.0')
    refute V.valid?('1.0.0; rm -rf')
  end
end

class TestLogger < Minitest::Test
  def test_redaction
    d = Dir.mktmpdir
    l = SL::Logger.new(File.join(d, 'a.log'))
    l.add_secret('my-secret-token-123456')
    l.error('Lỗi với key sk-proj-ABCDEFGHIJKLmnop và my-secret-token-123456, Authorization: Bearer abcdefghijklmnop')
    txt = File.read(File.join(d, 'a.log'), encoding: 'UTF-8')
    refute_includes txt, 'ABCDEFGHIJKL'
    refute_includes txt, 'my-secret-token-123456'
    refute_includes txt, 'abcdefghijklmnop'
    assert_includes txt, '[ẩn]'
  end
end

class TestSettings < Minitest::Test
  def setup
    @d = Dir.mktmpdir
    @f = File.join(@d, 'settings.json')
  end

  def test_migrate_legacy
    id = 'a' * 64
    File.write(@f, JSON.generate('roots' => ['C:\\Lib'], 'favorites' => [id, 'bad'], 'history' => [id], 'model' => 'gpt-4.1-mini'))
    s = SL::Settings.new(@f)
    assert_equal ['C:/Lib'], s.roots
    assert_equal [id], s['favorites']
    assert_equal 'gpt-6-luna', s['ai']['model'], 'model mặc định cũ (đã bị OpenAI ngừng) được chuyển sang mặc định mới'
    File.write(@f, JSON.generate('roots' => [], 'model' => 'my-custom-model'))
    assert_equal 'my-custom-model', SL::Settings.new(@f)['ai']['model']
  end

  def test_corrupt_restores_backup
    s = SL::Settings.new(@f)
    s.add_root('/lib/a'); s.save
    s.add_root('/lib/b'); s.save # .bak chứa /lib/a
    File.write(@f, '{hỏng')
    s2 = SL::Settings.new(@f)
    assert_match(/bị hỏng/, s2.load_warning)
    assert_equal ['/lib/a'], s2.roots
    refute_empty Dir.glob(File.join(@d, 'settings.json.corrupt-*'))
  end

  def test_whitelist_no_secrets
    s = SL::Settings.new(@f)
    s.apply_ui('ai' => { 'model' => 'gpt-6-sol', 'api_key' => 'sk-should-not-save' }, 'openai_key' => 'x',
               'update' => { 'source' => 'manifest', 'manifest_url' => 'http://insecure' })
    s.save
    raw = File.read(@f)
    refute_includes raw, 'sk-should'
    refute_includes raw, 'openai_key'
    assert_equal 'gpt-6-sol', s['ai']['model']
    assert_equal '', s['update']['manifest_url'], 'chỉ chấp nhận https'
  end

  def test_roots_dedupe_and_history
    s = SL::Settings.new(@f)
    assert s.add_root('/x/Lib')
    refute s.add_root('/x/Lib/')
    id = 'b' * 64
    400.times { |i| s.push_history(format('%064x', i)) }
    s.push_history(id)
    assert_equal id, s['history'].first
    assert_equal SL::Settings::HISTORY_MAX, s['history'].size
  end
end

class TestSearch < Minitest::Test
  def entries(names, root = '/lib')
    names.map.with_index { |n, i| SL::SearchIndex.build_entry("#{root}/#{n}", 1000 * (i + 1), 1_700_000_000 + i, root) }
  end

  def setup
    @idx = SL::SearchIndex.new
    @idx.replace(entries(['Noi that/Ghế sofa vải xám.skp', 'Noi that/Ban an go 6 cho.skp', 'Den/Pendant lamp brass.skp',
                          'Ngoai that/Cay xanh 01.skp', 'Kitchen/Modern dining table.skp', 'Da/Ghe da bo.skp',
                          'Stone/Ban tra da marble.skp', 'Tu/Tủ quần áo.skp', 'Tuong/tuong gach.skp']))
  end

  def names(r); r['items'].map { |x| x['name'] }; end

  def q(text, extra = {}); @idx.search({ query: text, tab: 'offline', per_page: 50 }.merge(extra)); end

  def test_accent_insensitive
    assert_equal ['Ghế sofa vải xám'], names(q('ghe sofa'))
    assert_includes names(q('GHẾ')), 'Ghe da bo'
  end

  def test_vi_to_en_and_en_to_vi
    assert_includes names(q('đèn')), 'Pendant lamp brass'
    assert_includes names(q('bàn ăn')), 'Modern dining table'
    assert_includes names(q('bàn ăn')), 'Ban an go 6 cho'
    assert_includes names(q('chair')), 'Ghế sofa vải xám'
    assert_includes names(q('wardrobe')), 'Tủ quần áo'
  end

  def test_short_token_word_prefix
    r = names(q('tu'))
    assert_includes r, 'Tủ quần áo'
    refute_includes r, 'Ban an go 6 cho'
  end

  def test_da_ambiguity
    assert_includes names(q('đá')), 'Ban tra da marble'
    assert_includes names(q('leather')), 'Ghe da bo'
  end

  def test_any_of_and_filters
    r = @idx.search(query: '', any_of: ['pendant lamp', 'cây xanh'], tab: 'offline', per_page: 50)
    assert_equal 2, r['total']
    r = q('', size_max_mb: 0, sort: 'large')
    assert_equal 'tuong gach', r['items'].first['name']
    fav = @idx.search(query: '', tab: 'favorites', favorites: [r['items'].last['id']], per_page: 10)
    assert_equal 1, fav['total']
  end

  def test_relevance_name_first
    r = names(q('table'))
    assert_equal 'Modern dining table', r.first
  end

  def test_pagination_clamped
    r = @idx.search(query: '', tab: 'offline', page: 99, per_page: 4)
    assert_equal 2, r['page']
    assert_equal 3, r['pages']
    assert_equal 1, r['items'].size
  end

  def test_performance_100k
    big = SL::SearchIndex.new
    words = %w[ghe ban tu den sofa chair table lamp go da vai kinh modern classic cay giuong]
    list = Array.new(100_000) do |i|
      SL::SearchIndex.build_entry("/lib/f#{i % 300}/#{words[i % 16]} #{words[(i / 16) % 16]} #{i}.skp", i, i, '/lib')
    end
    big.replace(list)
    t = Time.now
    r = big.search(query: 'ghế gỗ', tab: 'offline', per_page: 48)
    dt = Time.now - t
    t2 = Time.now
    big.search(query: 'ghế gỗ', tab: 'offline', page: 5, per_page: 48)
    dt2 = Time.now - t2
    puts "\n  [perf] 100k: tìm 'ghế gỗ' #{(dt * 1000).round} ms (#{r['total']} kết quả); lật trang (cache) #{(dt2 * 1000).round(2)} ms"
    assert r['total'] > 0
    assert dt < 2.5, 'tìm 100k model phải dưới 2.5s trên máy test'
    assert dt2 < 0.05
  end
end

class TestSketchfabParse < Minitest::Test
  SAMPLE = {
    'cursors' => { 'next' => '24', 'previous' => nil },
    'results' => [{
      'uid' => '9aea3b516d3e4e169710049b32282670', 'name' => '<img src=x onerror=alert(1)> Chair',
      'viewerUrl' => 'https://sketchfab.com/3d-models/none-9aea3b516d3e4e169710049b32282670', 'isDownloadable' => true,
      'thumbnails' => { 'images' => [{ 'url' => 'https://media.sketchfab.com/a/64.jpeg', 'width' => 64 },
                                     { 'url' => 'https://media.sketchfab.com/a/400.jpeg', 'width' => 400 },
                                     { 'url' => 'https://evil.example/x.jpeg', 'width' => 360 }] },
      'user' => { 'displayName' => 'Author', 'profileUrl' => 'https://sketchfab.com/author' },
      'license' => { 'label' => 'CC Attribution' }, 'faceCount' => 1000,
      'archives' => { 'glb' => { 'size' => 10 }, 'gltf' => { 'size' => 20 } }
    }, { 'uid' => 'not-valid' }]
  }.freeze

  def test_parse_search
    d = SL::Sketchfab.parse_search(JSON.generate(SAMPLE))
    assert_equal 1, d['items'].size
    it = d['items'][0]
    assert_equal 'https://media.sketchfab.com/a/400.jpeg', it['thumb']
    assert_equal %w[gltf glb], it['formats'].map { |f| f['type'] }
    assert_equal '24', d['next']
    assert_equal 'CC Attribution', it['license']
  end

  def test_search_url_and_auth
    u = SL::Sketchfab.search_url('ghế sofa', cursor: '24')
    assert_includes u, 'https://api.sketchfab.com/v3/search?'
    assert_includes u, 'q=gh%E1%BA%BF+sofa'
    assert_includes u, 'downloadable=true'
    refute_includes SL::Sketchfab.search_url('x', cursor: 'a&b=c'), 'cursor'
    assert_equal 'Token abc12345', SL::Sketchfab.auth_header('abc12345', 'token')
    assert_equal 'Bearer abc12345', SL::Sketchfab.auth_header('abc12345', 'bearer')
  end

  def test_parse_download
    d = SL::Sketchfab.parse_download(JSON.generate('gltf' => { 'url' => 'https://s3.example/a.zip?sig=1', 'size' => 5, 'expires' => 300 },
                                                   'usdz' => { 'url' => 'http://insecure/x' }))
    assert_equal ['gltf'], d.keys
    assert_equal '.zip', SL::Sketchfab.extension_for('gltf', d['gltf']['url'])
  end

  def test_link_sources
    assert_equal 'https://3dwarehouse.sketchup.com/search/?q=gh%E1%BA%BF+sofa', SL::LinkSources.url_for('warehouse', 'ghế sofa')
    assert_raises(RuntimeError) { SL::LinkSources.url_for('warehouse', '  ') }
    assert_raises(RuntimeError) { SL::LinkSources.url_for('evil', 'x') }
  end
end

class TestVision < Minitest::Test
  V = SL::Vision
  def test_mime
    assert_equal 'image/png', V.mime_of("\x89PNG\r\n\x1a\n....".b)
    assert_equal 'image/jpeg', V.mime_of("\xFF\xD8\xFF\xE0".b)
    assert_nil V.mime_of('%PDF-1.4')
  end

  def test_body
    b = JSON.parse(V.build_body(model: 'gpt-6-luna', mime: 'image/jpeg', b64: 'AAAA', detail: 'low'))
    assert_equal 'json_schema', b['response_format']['type']
    assert_equal 'low', b['reasoning_effort']
    assert b['max_completion_tokens']
    refute b.key?('max_tokens')
    assert_equal V::FIELDS.sort, b['response_format']['json_schema']['schema']['required'].sort
    b2 = JSON.parse(V.build_body(model: 'gpt-4.1-mini', mime: 'image/jpeg', b64: 'AAAA'))
    refute b2.key?('reasoning_effort')
  end

  def test_fallback_variants
    err = JSON.generate('error' => { 'message' => "Unsupported parameter: 'reasoning_effort'" })
    assert_equal [:no_reasoning], V.fallback_variant(400, err, [])
    err2 = JSON.generate('error' => { 'message' => 'Invalid parameter: response_format json_schema' })
    assert_equal [:no_reasoning, :json_object], V.fallback_variant(400, err2, [:no_reasoning])
    assert_nil V.fallback_variant(401, err, [])
  end

  def test_parse_result
    content = JSON.generate('object_type' => 'sofa', 'style' => 'modern', 'material' => 'fabric', 'color' => 'gray',
                            'queries_vi' => ['ghế sofa vải xám', '', 'ghế sofa vải xám'], 'queries_en' => ['gray fabric sofa'])
    body = JSON.generate('choices' => [{ 'message' => { 'content' => content } }], 'usage' => { 'total_tokens' => 99 })
    r = V.parse_result(body)
    assert_equal ['ghế sofa vải xám'], r['queries_vi']
    assert_equal 99, r['usage']['total_tokens']
    assert_raises(RuntimeError) { V.parse_result(JSON.generate('choices' => [{ 'message' => { 'content' => 'not json' } }])) }
    assert_raises(RuntimeError) { V.parse_result(JSON.generate('choices' => [{ 'message' => { 'refusal' => 'no', 'content' => nil } }])) }
  end

  def test_error_messages
    assert_match(/insufficient_quota/, V.error_message(429, JSON.generate('error' => { 'code' => 'insufficient_quota', 'message' => 'x' })))
    assert_match(/rate limit/, V.error_message(429, JSON.generate('error' => { 'code' => 'rate_limit_exceeded' })))
    assert_match(/401/, V.error_message(401, '{}'))
  end
end
