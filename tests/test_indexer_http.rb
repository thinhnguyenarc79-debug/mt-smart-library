# frozen_string_literal: true
require_relative 'test_helper'

class TestIndexer < Minitest::Test
  def setup
    @root = Dir.mktmpdir('thư_viện_')
    @cache = File.join(Dir.mktmpdir, 'index_cache.json')
    mk('Nội thất/Phòng khách/Ghế sofa đôi.skp', 'a' * 100)
    mk('Nội thất/Phòng khách/readme.txt', 'x')
    mk('Nội thất/Bếp/Tủ bếp chữ L.SKP', 'b' * 50)
    mk('Ngoại thất/Cây xanh.skp', 'c')
    mk('.hidden/secret.skp', 'z')
    mk('$RECYCLE.BIN/deleted.skp', 'z')
    File.symlink(@root, File.join(@root, 'Nội thất', 'loop'))           # vòng symlink
    File.symlink('/khong/ton/tai.skp', File.join(@root, 'dangling.skp')) # symlink hỏng
    bad = (File.join(@root, 'Ngoại thất').b + "/bad\xFFname.skp".b)
    File.binwrite(bad, 'x') # tên file sai UTF-8 => lỗi riêng từng file
  end

  def mk(rel, data)
    p = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(p))
    File.write(p, data)
  end

  def run_scan(ix, roots, full: false)
    ix.start(roots, full: full)
    res = nil
    wait_until(20) { (res = ix.poll) && res.status != :cancelled ? true : (ix.running? || res.nil? ? false : true) }
    res
  end

  def test_scan_unicode_errors_and_cache
    ix = SL::Indexer.new(@cache)
    res = run_scan(ix, [@root])
    assert_equal :done, res.status
    names = res.entries.map(&:name).sort
    assert_equal ['Cây xanh', 'Ghế sofa đôi', 'Tủ bếp chữ L'], names
    assert(res.errors.any? { |_, m| m.include?('UTF-8') }, 'tên file sai encoding phải được ghi lỗi riêng')
    assert File.file?(@cache)
    data = JSON.parse(File.read(@cache))
    assert_equal SL::Indexer::CACHE_SCHEMA, data['schema']
    refute_includes File.read(@cache), 'api_key'
    # ID tương thích bản cũ = SHA256(đường dẫn)
    e = res.entries.find { |x| x.name == 'Cây xanh' }
    assert_equal Digest::SHA256.hexdigest(e.path), e.id
    JSON.generate(res.entries.map { |x| x.path }) # không lỗi encoding

    # Nạp lại từ cache (khởi động lần sau)
    ix2 = SL::Indexer.new(@cache)
    assert_equal names, ix2.load_cache([@root]).map(&:name).sort

    # Quét nhanh: thêm 1 file, xóa 1 file
    sleep 1.1
    mk('Ngoại thất/Hàng rào.skp', 'd')
    File.delete(File.join(@root, 'Nội thất/Bếp/Tủ bếp chữ L.SKP'))
    res2 = run_scan(ix2, [@root])
    assert_equal ['Cây xanh', 'Ghế sofa đôi', 'Hàng rào'], res2.entries.map(&:name).sort
    assert res2.stats['reused'] > 0, 'thư mục không đổi phải dùng cache'
  end

  def test_offline_root_keeps_old_data
    ix = SL::Indexer.new(@cache)
    run_scan(ix, [@root])
    moved = @root + '_offline'
    File.rename(@root, moved)
    res = run_scan(ix, [@root])
    assert_equal 'offline', res.roots_state[@root]
    assert_equal 3, res.entries.size, 'ổ mạng tạm mất kết nối không làm mất thư viện'
  ensure
    File.rename(moved, @root) if moved && File.exist?(moved)
  end

  def test_cancel_and_restart_when_roots_change
    big = Dir.mktmpdir('big_')
    300.times { |i| d = File.join(big, "d#{i}"); FileUtils.mkdir_p(d); 5.times { |j| File.write(File.join(d, "m#{j}.skp"), 'x') } }
    ix = SL::Indexer.new(@cache)
    assert_equal :started, ix.start([big])
    assert_equal :restarting, ix.start([@root]) # thêm/xóa root khi đang quét
    results = []
    wait_until(20) { (r = ix.poll) && results << r; results.any? { |x| x.status == :done } }
    done = results.find { |x| x.status == :done }
    assert_equal 3, done.entries.size, 'kết quả cuối cùng phải theo danh sách root mới'
    # Hủy
    ix.start([big], full: true)
    ix.cancel
    r = nil
    wait_until(20) { r = ix.poll }
    assert_includes [:cancelled, :done], r.status
  end

  def test_corrupt_cache
    File.write(@cache, '{"schema":2,"dirs":')
    ix = SL::Indexer.new(@cache)
    assert_equal [], ix.load_cache([@root])
    assert_match(/hỏng/, ix.cache_info)
    assert File.exist?(@cache + '.corrupt')
  end
end

class TestThumbs < Minitest::Test
  def test_queue_and_failure_marker
    dir = Dir.mktmpdir
    root = Dir.mktmpdir
    good = File.join(root, 'a.skp'); File.write(good, 'x')
    e1 = SL::SearchIndex.build_entry(good, 1, 1, root)
    e2 = SL::SearchIndex.build_entry(File.join(root, 'missing.skp'), 1, 1, root)
    calls = 0
    t = SL::ThumbService.new(dir) { |skp, png| calls += 1; Sketchup.save_thumbnail(skp, png) }
    t.request([e1, e2, e1])
    out = {}
    t.process(5) { |id, src| out[id] = src }
    assert_match(/\Adata:image\/png;base64,/, out[e1.id])
    assert_nil out[e2.id]
    t.request([e1, e2])
    t.process(5) { |_id, _src| nil }
    assert_equal 2, calls, 'thumbnail đã có hoặc đã lỗi không bị tạo lại'
  end
end

class TestHttp < Minitest::Test
  def setup
    @mock = MockHTTP.new do |req|
      case req[:path]
      when '/ok' then [200, {}, '{"hello":"xin chào"}']
      when '/401' then [401, {}, '{"error":{"message":"bad key"}}']
      when '/slow' then sleep 3; [200, {}, '{}']
      when '/redirect' then [302, { 'Location' => "http://localhost:#{@port_ref}/landing" }, '']
      when '/landing' then [200, {}, JSON.generate('auth' => req[:headers]['authorization'])]
      when '/file' then [200, { 'Content-Type' => 'application/octet-stream' }, 'Z' * 50_000]
      else [404, {}, '{}']
      end
    end
    @port_ref = @mock.port
    @c = SL::HttpClient.new
  end

  def teardown
    @mock.close
  end

  def get(path, extra = {})
    res = nil
    @c.request({ url: @mock.url(path) }.merge(extra)) { |r| res = r }
    wait_http(@c) { res }
    res
  end

  def test_ok_401_timeout
    r = get('/ok')
    assert r.ok
    assert_equal 'xin chào', r.json['hello']
    r = get('/401')
    refute r.ok
    assert_equal 401, r.code
    r = get('/slow', timeout: 1)
    assert_equal :timeout, r.error_kind
    assert_match(/timeout/i, SL::HttpClient.friendly(r))
  end

  def test_network_error
    res = nil
    @c.request(url: 'http://127.0.0.1:1/x', timeout: 3) { |r| res = r }
    wait_http(@c) { res }
    assert_equal :network, res.error_kind
  end

  def test_redirect_strips_auth_cross_host
    r = get('/redirect', headers: { 'Authorization' => 'Token secret123' })
    assert r.ok
    assert_nil r.json['auth'], 'không gửi Authorization sang host khác khi chuyển hướng'
  end

  def test_download_with_progress
    dest = File.join(Dir.mktmpdir, 'sub', 'f.bin')
    prog = {}
    r = get('/file', dest: dest, progress: prog)
    assert r.ok
    assert_equal 50_000, File.size(dest)
    assert_equal 50_000, prog['bytes']
    refute File.exist?(dest + '.part')
  end
end
