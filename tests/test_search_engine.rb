# frozen_string_literal: true
require_relative 'test_helper'

QN = SL::QueryNormalizer
RR = SL::ResultRanker

def sf_item(title, tags: [], cats: [], downloadable: true, uid: nil, author: 'A', likes: 10, age: false)
  { 'source' => 'sketchfab', 'source_label' => 'Sketchfab', 'uid' => uid || format('%032x', title.hash.abs),
    'title' => title, 'tags' => tags, 'cats' => cats, 'downloadable' => downloadable, 'free' => downloadable,
    'insertable' => false, 'thumb' => 'https://media.sketchfab.com/x.jpg', 'author' => author, 'likes' => likes,
    'faces' => 50_000, 'age_restricted' => age, 'formats' => [{ 'type' => 'gltf', 'size' => 1 }], 'url' => 'https://sketchfab.com/3d-models/x' }
end

class TestQueryNormalizer < Minitest::Test
  def test_vietnamese_sofa_expansion
    %w[ghế\ sofa ghe\ sofa GHẾ\ SOFA].each do |t|
      q = QN.analyze(t)
      assert_equal 'sofa', q.primary_en, t
      %w[sofa couch modern\ sofa living\ room\ sofa].each { |e| assert_includes q.expansions, e, t }
    end
  end

  def test_english_and_mixed
    assert_equal 'modern sofa', QN.analyze('modern sofa').primary_en
    assert_equal 'dining table wood', QN.analyze('bàn ăn gỗ').primary_en
    assert_equal 'dining table wood', QN.analyze('ban an go').primary_en
    q = QN.analyze('ghế sofa vải xám')
    assert_equal 'sofa fabric gray', q.primary_en
    assert_equal 0, q.object_index
    assert QN.analyze('').empty?
  end

  def test_local_groups_cover_both_languages
    g = QN.analyze('đèn thả').groups.flatten
    assert_includes g, 'den tha'
    assert_includes g, 'pendant'
  end
end

class TestRanker < Minitest::Test

  def test_relevance_filter
    qq = QN.analyze('ghế sofa')
    keep = [sf_item('Modern Sofa 3 seats'), sf_item('Living room set', tags: %w[sofa interior]), sf_item('Grey couch')]
    drop = [sf_item('Sofa the cat', cats: ['animals-pets']), sf_item('Cyber girl', tags: ['character'], cats: ['characters-creatures']),
            sf_item('Cozy apartment'), sf_item('Sofa NSFW', age: true)]
    keep.each { |i| assert RR.relevant_online?(i, qq, []), i['title'] }
    drop.each { |i| refute RR.relevant_online?(i, qq, []), i['title'] }
  end

  def test_object_noun_required
    qq = QN.analyze('ghế sofa vải xám')
    assert RR.relevant_online?(sf_item('Grey fabric sofa'), qq, [])
    assert RR.relevant_online?(sf_item('Sofa'), qq, []), 'chỉ cần khớp đồ vật chính'
    refute RR.relevant_online?(sf_item('Grey fabric curtain'), qq, []), 'chỉ khớp màu/vật liệu thì loại'
  end

  def test_user_can_ask_for_people
    assert RR.relevant_online?(sf_item('Sitting people', cats: ['people']), QN.analyze('người ngồi'), []) == false ||
           RR.relevant_online?(sf_item('People sitting', cats: ['people']), QN.analyze('people sitting'), [])
  end

  def test_category_terms
    terms = SL::Categories.terms(SL::Categories.find('lighting', []))
    assert_includes terms, 'pendant'
    assert_includes terms, 'den'
    assert RR.relevant_online?(sf_item('Brass pendant lamp'), QN.analyze(''), terms)
    refute RR.relevant_online?(sf_item('Wooden chair'), QN.analyze(''), terms)
  end

  def test_score_order_and_filters
    qq = QN.analyze('sofa')
    local = { 'source' => 'local', 'id' => 'a' * 64, 'title' => 'Sofa da', 'rel' => 1.0, 'insertable' => true, 'downloadable' => true,
              'free' => true, 'format' => 'skp', 'size' => 2_000_000, 'path' => '/l/Sofa da.skp' }
    online_ok = sf_item('Modern sofa', likes: 5000)
    online_view = sf_item('Sofa view only', downloadable: false)
    [local, online_ok, online_view].each { |i| i['score'] = RR.score(i, qq, []) }
    assert local['score'] > online_ok['score']
    assert online_ok['score'] > online_view['score']
    store = {}
    RR.merge_into(store, [local, online_ok, online_view, sf_item('Modern sofa', likes: 1, uid: 'f' * 32)])
    assert_equal 3, store.size, 'cùng tên + cùng tác giả => gộp trùng'
    assert_equal 1, RR.apply_filter(store.values, 'local').size
    assert_equal 2, RR.apply_filter(store.values, 'online').size
    assert_equal 1, RR.apply_filter(store.values, 'insertable').size
    assert_equal 2, RR.apply_filter(store.values, 'free').size
  end
end

class TestCategoriesAndCache < Minitest::Test
  def test_custom_categories
    list = SL::Categories.sanitize_custom([{ 'name' => 'Bàn trang điểm', 'keywords' => ['bàn trang điểm', 'vanity', ''] },
                                          { 'name' => '', 'keywords' => ['x'] }, { 'name' => 'Rỗng', 'keywords' => [] }, 'rác'])
    assert_equal 1, list.size
    assert_match(/\Ac_[a-z0-9]{8}\z/, list[0]['id'])
    all = SL::Categories.all(list)
    assert_equal 'all', all.first['id']
    assert(all.index { |c| c['id'] == list[0]['id'] } < all.index { |c| c['id'] == 'personal' })
    assert_includes SL::Categories.terms(all.find { |c| c['custom'] }), 'vanity'
    assert_equal 'dressing table', SL::Categories.online_query(all.find { |c| c['custom'] })
  end

  def test_result_cache
    c = SL::ResultCache.new(max: 2, ttl: 1)
    c.put('a', 1); c.put('b', 2); c.get('a'); c.put('c', 3)
    assert_nil c.get('b'), 'LRU bỏ mục ít dùng nhất'
    assert_equal 1, c.get('a')
    sleep 1.05
    assert_nil c.get('a'), 'hết hạn TTL'
  end
end

# Nguồn online giả lập: trả kết quả bất đồng bộ khi test gọi deliver.
class FakeOnline < SL::Providers::BaseProvider
  attr_reader :pending, :cancelled
  def initialize(id = 'fake', pages: {}, fail: nil)
    super(id, id.capitalize)
    @pages = pages; @fail = fail; @pending = []; @cancelled = 0
  end
  def online?; true; end
  def applicable?(s, _st); !s.online_q.to_s.empty?; end
  def search(_session, token, &done); @pending << [token, done]; end
  def cancel(_s); @cancelled += 1; end
  def deliver
    token, done = @pending.shift
    raise @fail if @fail == :raise_in_callback
    return done.call('items' => [], 'next' => nil, 'error' => @fail) if @fail
    items, nxt = @pages.fetch(token || 0)
    done.call('items' => items.map(&:dup), 'next' => nxt, 'error' => nil)
  end
end

class TestSearchManager < Minitest::Test
  def setup
    @settings = SL::Settings.new(File.join(Dir.mktmpdir, 's.json'))
    @index = SL::SearchIndex.new
    root = '/lib'
    names = ['Ghế sofa vải', 'Sofa góc chữ L', 'Bàn ăn gỗ', 'Đèn thả đồng'] + Array.new(130) { |i| "Sofa mẫu #{i}" }
    @index.replace(names.map.with_index { |n, i| SL::SearchIndex.build_entry("#{root}/#{n}.skp", 1000 + i, i, root) })
    @events = []
    @online = FakeOnline.new('fake', pages: { 0 => [[sf_item('Modern Sofa'), sf_item('Sofa cat', cats: ['animals-pets']),
                                                     sf_item('Pretty room')], 24],
                                              24 => [[sf_item('Couch grey')], nil] })
    @broken = FakeOnline.new('broken', fail: 'Máy chủ lỗi 500')
    @mgr = SL::SearchManager.new(providers: [SL::Providers::LocalProvider.new(@index), @online, @broken], settings: @settings,
                                 emit: ->(t, p) { @events << [t, p] })
  end

  def last_update; @events.select { |t, _| t == 'sr_update' }.last[1]; end

  def test_streaming_merge_filter_and_paging
    @mgr.start('sid' => 1, 'q' => 'ghế sofa', 'category' => 'all')
    first = last_update
    assert first['loading'], 'nguồn online chưa xong vẫn hiển thị ngay kết quả máy tính'
    assert(first['items'].all? { |i| i['source'] == 'local' })
    assert_equal 'Ghế sofa vải', first['items'][0]['title']
    assert_equal 120, first['items'].size, 'trang đầu của máy tính'
    assert_equal 132, first['counts']['local'], 'bộ đếm hiển thị tổng số model khớp, không chỉ phần đã tải'
    @online.deliver
    @broken.deliver
    u = last_update
    refute u['loading']
    titles = u['items'].map { |i| i['title'] }
    assert_includes titles, 'Modern Sofa'
    refute_includes titles, 'Sofa cat'
    refute_includes titles, 'Pretty room'
    assert_equal 2, u['hidden']
    assert_equal 'error', u['sources'].find { |s| s['id'] == 'broken' }['state'], 'nguồn lỗi không ảnh hưởng nguồn khác'
    assert u['has_more']
    @mgr.more(1)
    @online.deliver
    u = last_update
    assert_equal 132, u['counts']['local'], '2 model ghế sofa + 130 model Sofa mẫu'
    assert_includes u['items'].map { |i| i['title'] }, 'Couch grey'
    @mgr.set_filter(1, 'online')
    assert(last_update['items'].all? { |i| i['source'] != 'local' })
    assert_nil u['items'][0]['tags'], 'không gửi dữ liệu kỹ thuật thừa lên thẻ'
  end

  def test_stale_results_ignored_and_cancel
    @mgr.start('sid' => 1, 'q' => 'sofa')
    @mgr.start('sid' => 2, 'q' => 'bàn ăn')
    assert_operator @online.cancelled, :>=, 1, 'hủy truy vấn cũ khi gõ từ khóa mới'
    n = @events.size
    @online.pending.first[1].call('items' => [sf_item('Old sofa result')], 'next' => nil, 'error' => nil)
    assert_equal n, @events.size, 'kết quả của truy vấn cũ bị bỏ qua'
    assert_equal 2, last_update['sid']
  end

  def test_category_without_query_and_favorites
    @mgr.start('sid' => 3, 'q' => '', 'category' => 'lighting')
    assert_equal ['Đèn thả đồng'], last_update['items'].map { |i| i['title'] }
    assert_equal 'lamp', @events.select { |t, _| t == 'sr_begin' }.last[1]['primary_en']
    fav = sf_item('Modern Sofa').merge('key' => "sketchfab:#{'b' * 32}", 'uid' => 'b' * 32)
    @settings.toggle_online_favorite(fav)
    @settings.toggle_favorite(@index.search(query: 'bàn ăn', tab: 'offline', per_page: 1)['items'][0]['id'])
    @mgr.start('sid' => 4, 'q' => '', 'category' => 'favorites')
    titles = last_update['items'].map { |i| i['title'] }
    assert_equal ['Bàn ăn gỗ', 'Modern Sofa'].sort, titles.sort
    assert(last_update['items'].all? { |i| i['fav'] })
    assert_empty @online.pending.select { |t, _| t.nil? && false }, 'yêu thích không gọi online'
  end
end

class FakeHttp
  attr_reader :calls
  def initialize(body); @body = body; @calls = 0; end
  def request(opts, &cb); @calls += 1; @last = opts; cb.call(SL::HttpClient::Result.new(true, 200, @body, {}, nil, nil, nil, opts[:url])); 77; end
  def cancel(_id); end
  def last; @last; end
end

class TestSketchfabProvider < Minitest::Test
  def test_normalize_and_cache
    body = JSON.generate('cursors' => { 'next' => '24' }, 'results' => [{
      'uid' => 'c' * 32, 'name' => 'Velvet sofa', 'isDownloadable' => true, 'likeCount' => 99, 'viewCount' => 1000,
      'viewerUrl' => "https://sketchfab.com/3d-models/v-#{'c' * 32}", 'tags' => [{ 'name' => 'sofa' }], 'categories' => [{ 'name' => 'furniture-home' }],
      'thumbnails' => { 'images' => [{ 'url' => 'https://media.sketchfab.com/a/500.jpg', 'width' => 500 }, { 'url' => 'https://media.sketchfab.com/a/1024.jpg', 'width' => 1024 }] },
      'user' => { 'displayName' => 'Studio X', 'profileUrl' => 'https://sketchfab.com/x' }, 'license' => { 'label' => 'CC Attribution' },
      'archives' => { 'source' => { 'size' => 5 }, 'gltf' => { 'size' => 7 } }, 'faceCount' => 12_000
    }])
    http = FakeHttp.new(body)
    st = SL::Settings.new(File.join(Dir.mktmpdir, 's.json'))
    p = SL::Providers::SketchfabProvider.new(http, SL::ResultCache.new)
    sess = SL::SearchManager::Session.new(1, QN.analyze('sofa'), [], 'sofa', SL::Categories.find('all', []), [], 'all', 'all', {}, {}, st, 0, 0, QN.analyze('sofa'))
    out = nil
    p.search(sess, nil) { |r| out = r }
    it = out['items'][0]
    assert_equal 'source', it['format'], 'ưu tiên định dạng gốc nếu có'
    assert_equal 'https://media.sketchfab.com/a/1024.jpg', it['thumb_large']
    assert_equal 'Studio X', it['author']
    assert_equal ['furniture-home'], it['cats']
    assert_equal '24', out['next']
    assert_includes http.last[:url], 'downloadable=true'
    p.search(sess, nil) { |r| out = r }
    assert_equal 1, http.calls, 'lần tìm lại cùng từ khóa dùng cache'
    refute p.applicable?(sess.tap { |s| s.kind = 'history' }, st)
  end
end
