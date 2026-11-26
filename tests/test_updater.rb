# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

class TestUpdater < Minitest::Test
  def setup
    ENV['MT_TEST_ALLOW_HTTP'] = '1' # máy chủ giả lập http://127.0.0.1 (bản thật bắt buộc https)
    @tmp = Dir.mktmpdir('upd_')
    @plugins = File.join(@tmp, 'Plugins')
    @data = File.join(@tmp, 'Data')
    FileUtils.mkdir_p(@plugins)
    FileUtils.cp(File.join(SRC, 'mt_smart_library.rb'), @plugins)
    FileUtils.cp_r(File.join(SRC, 'mt_smart_library'), @plugins)
    # Dữ liệu người dùng giả lập — phải còn nguyên sau mọi thao tác cập nhật
    FileUtils.mkdir_p(File.join(@data, 'thumbs'))
    File.write(File.join(@data, 'settings.json'), '{"schema":2,"roots":["D:/Thu vien"],"favorites":["' + 'a' * 64 + '"]}')
    File.write(File.join(@data, 'index_cache.json'), '{"schema":2,"dirs":{}}')
    File.binwrite(File.join(@data, 'thumbs', 'x.png'), 'PNG')
    @user_snapshot = snapshot(@data)
    @log = SL::Logger.new(File.join(@data, 'logs', 'test.log'))
    @http = SL::HttpClient.new(@log)
    @u = SL::Updater.new(logger: @log, http: @http, plugins_root: @plugins, data_root: @data)
  end

  def snapshot(dir)
    Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }.sort.map { |f| [f, File.binread(f)] }.to_h
  end

  def user_data_intact?
    now = snapshot(@data).select { |k, _| @user_snapshot.key?(k) }
    now == @user_snapshot
  end

  def installed_version
    File.read(File.join(@plugins, 'mt_smart_library', 'updater', 'version.rb'))[/VERSION = '([^']+)'/, 1]
  end

  # Tạo gói từ mã nguồn thật, đổi số phiên bản.
  def make_pkg(version, prefix: '', plugin_id: nil, min_su: nil, ext: 'rbz', extra: nil)
    st = Dir.mktmpdir('pkg_')
    base = prefix.empty? ? st : File.join(st, prefix)
    FileUtils.mkdir_p(base)
    FileUtils.cp(File.join(SRC, 'mt_smart_library.rb'), base)
    FileUtils.cp_r(File.join(SRC, 'mt_smart_library'), base)
    vf = File.join(base, 'mt_smart_library', 'updater', 'version.rb')
    v = File.read(vf).sub(/VERSION = '[^']+'/, "VERSION = '#{version}'")
    v = v.sub(/PLUGIN_ID = '[^']+'/, "PLUGIN_ID = '#{plugin_id}'") if plugin_id
    v = v.sub(/MIN_SKETCHUP = \d+/, "MIN_SKETCHUP = #{min_su}") if min_su
    File.write(vf, v)
    mf = File.join(base, 'mt_smart_library', 'updater', 'update_manifest.json')
    m = JSON.parse(File.read(mf)).merge('version' => version, 'changelog' => ["Bản thử #{version}"])
    m['plugin_id'] = plugin_id if plugin_id
    File.write(mf, JSON.generate(m))
    File.write(File.join(base, 'mt_smart_library', 'NEW_IN_' + version.tr('.', '_') + '.txt'), 'new')
    extra&.call(base)
    out = File.join(Dir.mktmpdir, "pkg_#{version}.#{ext}")
    _o, s = Open3.capture2e('zip', '-r', '-X', '-q', out, '.', chdir: st)
    raise 'zip failed' unless s.success?
    out
  end

  def py_zip(entries, symlink: nil)
    out = File.join(Dir.mktmpdir, 'evil.zip')
    script = +"import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\n"
    entries.each { |name, data| script << "z.writestr(#{name.inspect},#{data.inspect})\n" }
    if symlink
      script << "i=zipfile.ZipInfo(#{symlink.inspect});i.create_system=3;i.external_attr=(0o120777<<16)\nz.writestr(i,'/etc/passwd')\n"
    end
    script << "z.close()\n"
    Open3.capture2e('python3', '-c', script, out)
    out
  end

  def run_install(info, reason = 'Cập nhật từ file')
    assert @u.start_install(info, reason)
    @u.thread.join(30)
    ev = @u.events
    refute_empty ev
    ev.last
  end

  # ------------------------------------------------------------------ tests
  def test_full_update_backup_restore_cycle
    File.write(File.join(@plugins, 'mt_smart_library', 'stale_old_file.rb'), '# cũ')
    pkg = make_pkg('1.2.1')
    info = @u.inspect_package(pkg, su_major: 22)
    assert_equal '1.2.1', info['version']
    assert_equal 'newer', info['relation']
    assert info['compatible']
    assert_equal ['Bản thử 1.2.1'], info['changelog']
    type, payload = run_install(info)
    assert_equal :install_done, type, payload.inspect
    assert_equal '1.2.1', installed_version
    assert File.file?(File.join(@plugins, 'mt_smart_library', 'NEW_IN_1_2_1.txt'))
    refute File.exist?(File.join(@plugins, 'mt_smart_library', 'stale_old_file.rb')), 'file thừa của bản cũ được dọn'
    refute File.exist?(File.join(@plugins, 'mt_smart_library.__old__'))
    refute File.exist?(File.join(@plugins, 'mt_smart_library.rb.bak'))
    assert_equal 1, Dir.glob(File.join(@plugins, '*.rb')).size, 'không tạo loader trùng'
    assert user_data_intact?, 'dữ liệu người dùng phải giữ nguyên'
    assert_equal '1.2.1', @u.pending_restart_version
    b = @u.backups.list
    assert_equal 1, b.size
    assert_equal SL::VERSION, b[0]['version']
    assert_equal 'ok', @u.history.first['status']
    assert_includes File.read(@u.log_path), "#{SL::VERSION} -> 1.2.1"

    # Khôi phục bản trước
    rinfo = @u.inspect_backup(b[0]['id'], su_major: 22)
    assert_equal SL::VERSION, rinfo['version']
    type, = run_install(rinfo, 'Khôi phục phiên bản')
    assert_equal :install_done, type
    assert_equal SL::VERSION, installed_version
    refute File.exist?(File.join(@plugins, 'mt_smart_library', 'NEW_IN_1_2_1.txt'))
    assert File.exist?(File.join(@plugins, 'mt_smart_library', 'stale_old_file.rb')), 'khôi phục đúng nguyên trạng bản cũ'
    assert_equal 2, @u.backups.list.size
    assert user_data_intact?
  end

  def test_auto_rollback_when_verify_fails
    pkg = make_pkg('1.2.2')
    info = @u.inspect_package(pkg, su_major: 22)
    before = snapshot(@plugins)
    @u.define_singleton_method(:verify_tree!) do |src|
      @fail_once = !@fail_once
      raise 'Mô phỏng lỗi ghi file' if @fail_once
      super(src)
    end
    type, payload = run_install(info)
    assert_equal :install_failed, type
    assert_match(/Mô phỏng/, payload['error'])
    assert_match(/khôi phục/, payload['rollback'])
    assert_equal before, snapshot(@plugins), 'thư mục plugin trở lại y nguyên bản trước'
    assert_equal 'failed', @u.history.first['status']
    assert user_data_intact?
  end

  def test_wrapped_folder_zip_accepted
    pkg = make_pkg('1.1.0', prefix: 'MT_SMART_LIBRARY_PRO_1.1.0', ext: 'zip')
    info = @u.inspect_package(pkg, su_major: 22)
    assert_equal 'MT_SMART_LIBRARY_PRO_1.1.0/', info['prefix']
    type, = run_install(info)
    assert_equal :install_done, type
    assert_equal '1.1.0', installed_version
  end

  def test_rejects_wrong_plugin_id
    pkg = make_pkg('2.0.0', plugin_id: 'other.plugin')
    e = assert_raises(RuntimeError) { @u.inspect_package(pkg) }
    assert_match(/định danh|plugin_id/, e.message)
  end

  def test_incompatible_blocked
    pkg = make_pkg('2.0.0', min_su: 25)
    info = @u.inspect_package(pkg, su_major: 22)
    refute info['compatible']
    before = snapshot(@plugins)
    type, = run_install(info)
    assert_equal :install_failed, type
    assert_equal before, snapshot(@plugins)
  end

  def test_older_version_relation
    pkg = make_pkg('0.9.0')
    assert_equal 'older', @u.inspect_package(pkg)['relation']
  end

  def test_dangerous_paths_rejected
    base = { 'mt_smart_library.rb' => 'SketchupExtension.new mt_smart_library/main', 'mt_smart_library/main.rb' => '#',
             'mt_smart_library/updater/version.rb' => "PLUGIN_ID = 'mtdesign.smart_library_pro'\nVERSION = '9.0.0'",
             'mt_smart_library/updater/update_manifest.json' => '{}' }
    [['../evil.rb', /\.\./], ['/etc/evil.rb', /tuyệt đối/], ['C:/evil.rb', /tuyệt đối|:/], ['mt_smart_library/a\\..\\..\\x.rb', /\\/],
     ['mt_smart_library/con.rb', /thiết bị/], ['mt_smart_library/x.rb:ads', /:/]].each do |name, rx|
      z = py_zip(base.merge(name => 'x'))
      e = assert_raises(RuntimeError, name) { @u.inspect_package(z) }
      assert_match(rx, e.message, name)
    end
    z = py_zip(base, symlink: 'mt_smart_library/link.rb')
    assert_match(/symlink/, assert_raises(RuntimeError) { @u.inspect_package(z) }.message)
  end

  def test_missing_files_and_garbage
    z = py_zip({ 'mt_smart_library.rb' => 'x' })
    assert_match(/thiếu|Không tìm thấy/, assert_raises(RuntimeError) { @u.inspect_package(z) }.message)
    g = File.join(Dir.mktmpdir, 'x.rbz'); File.write(g, 'not a zip at all, sorry')
    assert_match(/không hợp lệ/i, assert_raises(RuntimeError) { @u.inspect_package(g) }.message)
    assert_raises(RuntimeError) { @u.inspect_package(File.join(Dir.mktmpdir, 'a.exe')) }
  end

  def test_corrupted_package_crc
    pkg = make_pkg('1.2.3')
    e = SL::ZipReader.new(pkg).entries.find { |x| x.name == 'mt_smart_library/updater/version.rb' }
    bytes = File.binread(pkg)
    nlen, elen = bytes.byteslice(e.offset + 26, 4).unpack('vv')
    pos = e.offset + 30 + nlen + elen + 10
    bytes.setbyte(pos, bytes.getbyte(pos) ^ 0xFF)
    File.binwrite(pkg, bytes)
    err = assert_raises(RuntimeError) { @u.inspect_package(pkg) }
    assert_match(/CRC|Giải nén|kích thước/, err.message)
  end

  def test_manifest_validation
    good = { 'plugin_id' => SL::PLUGIN_ID, 'version' => '1.2.0', 'download_url' => 'https://example.com/a.rbz',
             'sha256' => 'a' * 64, 'changelog' => "Dòng 1\nDòng 2" }
    m = @u.parse_manifest_json(JSON.generate(good), embedded: false)
    assert_equal ['Dòng 1', 'Dòng 2'], m['changelog']
    { 'download_url' => 'http://x/a.rbz', 'sha256' => 'xyz', 'plugin_id' => 'khac', 'version' => 'abc' }.each do |k, v|
      assert_raises(RuntimeError, k) { @u.parse_manifest_json(JSON.generate(good.merge(k => v)), embedded: false) }
    end
  end

  def test_online_download_sha256_and_install
    pkg = make_pkg('1.3.0')
    sha = Digest::SHA256.file(pkg).hexdigest
    mock = MockHTTP.new do |req|
      case req[:path]
      when '/manifest.json'
        [200, {}, JSON.generate('plugin_id' => SL::PLUGIN_ID, 'version' => '1.3.0', 'download_url' => 'https://example.invalid/x.rbz',
                                'sha256' => sha, 'size' => File.size(pkg), 'min_sketchup' => 22, 'changelog' => ['Online'])]
      when '/pkg.rbz' then [200, { 'Content-Type' => 'application/octet-stream' }, File.binread(pkg)]
      when '/bad.rbz' then [200, {}, 'tampered']
      end
    end
    got = nil
    @u.fetch_manifest(mock.url('/manifest.json'), 22) { |k, d| got = [k, d] }
    wait_http(@http) { got }
    assert_equal :ok, got[0], got.inspect
    assert_equal 'newer', got[1]['relation']
    # Thay URL tải bằng máy chủ giả lập (manifest thật bắt buộc https)
    m = got[1]
    @u.instance_variable_get(:@last_manifest)['download_url'] = mock.url('/bad.rbz')
    res = nil
    @u.download_package(m) { |k, d| res = [k, d] }
    wait_http(@http) { res }
    assert_equal :error, res[0]
    assert_match(/SHA256/, res[1])
    @u.instance_variable_get(:@last_manifest)['download_url'] = mock.url('/pkg.rbz')
    res = nil
    @u.download_package(m) { |k, d| res = [k, d] }
    wait_http(@http) { res }
    assert_equal :ok, res[0], res.inspect
    info = @u.inspect_package(res[1], su_major: 22)
    type, = run_install(info, 'Cập nhật online')
    assert_equal :install_done, type
    assert_equal '1.3.0', installed_version
    assert user_data_intact?
  ensure
    mock&.close
  end

  def test_backup_pruning
    7.times { |i| @u.backups.create("1.0.#{i}", 'test'); sleep 1.05 if i == 6 }
    assert_operator @u.backups.list.size, :<=, SL::BackupManager::KEEP + 1
  end

  def test_startup_report
    File.write(File.join(@data, 'update_state.json'), JSON.generate('pending_version' => SL::VERSION, 'from' => '0.9.0'))
    assert_match(/thành công/, @u.startup_report)
    assert_nil @u.startup_report
  end

  # ---------------------------------------------------------------- V1.0.15: kênh GitHub chính thức
  OFFICIAL_DL = "https://github.com/#{SL::UpdateChannel::REPO}/releases/download/v1.3.0/MT_SMART_LIBRARY_PRO_v1.3.0.rbz"

  def official_manifest(pkg, extra = {})
    JSON.generate({ 'schema' => 1, 'plugin_id' => SL::PLUGIN_ID, 'version' => '1.3.0', 'released_at' => '2026-11-26',
                    'download_url' => OFFICIAL_DL, 'sha256' => Digest::SHA256.file(pkg).hexdigest, 'size' => File.size(pkg),
                    'min_sketchup' => 22, 'min_ruby' => '2.7.0', 'restart_required' => true, 'changelog' => ['Bản thử'] }.merge(extra))
  end

  def test_new_machine_gets_official_channel_without_any_input
    dir = Dir.mktmpdir('newpc_')
    st = SL::Settings.new(File.join(dir, 'settings.json'))
    up = st['update']
    assert_equal 'official', up['source'], 'máy mới: kênh chính thức, không cần nhập URL/token'
    assert up['check_on_start'], 'tự kiểm tra khi mở plugin'
    assert st.save
    st2 = SL::Settings.new(File.join(dir, 'settings.json'))
    assert_equal 'official', st2['update']['source']
    refute File.read(File.join(dir, 'settings.json')).match?(/"(?:api_key|key|token|password|secret)"\s*:\s*"[^"]+"/i), 'không có giá trị bí mật trong settings'
  end

  def test_existing_sources_migration_rules
    dir = Dir.mktmpdir('mig_')
    f = File.join(dir, 'settings.json')
    load = lambda do |up|
      File.write(f, JSON.generate('schema' => 2, 'update' => up))
      SL::Settings.new(f)['update']
    end
    raw_main = "https://raw.githubusercontent.com/#{SL::UpdateChannel::REPO}/main/releases/update_manifest.json"
    m = load.call('source' => 'manifest', 'manifest_url' => raw_main, 'check_on_start' => false)
    assert_equal 'official', m['source'], 'cấu hình V1.0.14 của máy anh (raw main) → kênh chính thức'
    assert m['check_on_start'], 'bật tự kiểm tra một lần'
    pinned = "https://raw.githubusercontent.com/#{SL::UpdateChannel::REPO}/05038cb7ff39b61f401f397dd360014664f074d7/releases/update_manifest.json"
    assert_equal 'official', load.call('source' => 'manifest', 'manifest_url' => pinned)['source'], 'URL ghim commit cũ (không bao giờ thấy bản mới) → kênh chính thức'
    custom = load.call('source' => 'manifest', 'manifest_url' => 'https://cong-ty.example/mt/update_manifest.json', 'check_on_start' => false)
    assert_equal 'manifest', custom['source'], 'nguồn riêng hợp lệ giữ nguyên'
    refute custom['check_on_start'], 'không bật tự kiểm tra cho nguồn riêng'
    assert_equal 'lan', load.call('source' => 'lan', 'lan_folder' => '//server/share/mt')['source']
    assert_equal 'github', load.call('source' => 'github', 'github_repo' => 'khac/repo')['source']
    assert_equal 'official', load.call('source' => 'github', 'github_repo' => SL::UpdateChannel::REPO)['source']
    off = load.call('source' => 'none', 'auto_check_set' => true, 'check_on_start' => false)
    assert_equal 'none', off['source'], 'người dùng đã chủ động tắt → giữ'
    off2 = load.call('source' => 'official', 'auto_check_set' => true, 'check_on_start' => false)
    refute off2['check_on_start'], 'người dùng đã tắt tự kiểm tra → giữ'
  end

  def test_official_channel_falls_back_and_validates
    pkg = make_pkg('1.3.0')
    mock = MockHTTP.new do |req|
      case req[:path]
      when '/latest.json' then [404, {}, 'Not Found']
      when '/main.json' then [200, {}, official_manifest(pkg)]
      when '/foreign.json' then [200, {}, official_manifest(pkg, 'download_url' => 'https://evil.example/x.rbz')]
      when '/nosize.json' then [200, {}, official_manifest(pkg, 'size' => 0)]
      when '/broken.json' then [200, {}, '{"plugin_id": ']
      when '/wrongid.json' then [200, {}, official_manifest(pkg, 'plugin_id' => 'khac.plugin')]
      when '/old_su.json' then [200, {}, official_manifest(pkg, 'min_sketchup' => 99)]
      end
    end
    got = nil
    @u.fetch_official([mock.url('/latest.json'), mock.url('/main.json')], 22, []) { |k, d| got = [k, d] }
    wait_http(@http) { got }
    assert_equal :ok, got[0], got.inspect
    assert_equal mock.url('/main.json'), got[1]['manifest_url'], 'URL chính lỗi 404 → dùng URL dự phòng'
    assert_equal '1.3.0', got[1]['version']
    assert_equal 'newer', got[1]['relation']
    assert got[1]['restart_required']
    { '/foreign.json' => /kho phát hành chính thức/, '/nosize.json' => /dung lượng/, '/broken.json' => /cú pháp/,
      '/wrongid.json' => /plugin_id/ }.each do |path, rx|
      got = nil
      @u.fetch_official([mock.url(path)], 22, []) { |k, d| got = [k, d] }
      wait_http(@http) { got }
      assert_equal :error, got[0], path
      assert_match rx, got[1], path
    end
    got = nil
    @u.fetch_official([mock.url('/old_su.json')], 22, []) { |k, d| got = [k, d] }
    wait_http(@http) { got }
    refute got[1]['compatible'], 'SketchUp không tương thích → không cho cài'
  ensure
    mock&.close
  end

  def test_offline_github_unreachable_keeps_current_version
    before = installed_version
    port = TCPServer.new('127.0.0.1', 0).tap { |s| @p = s.addr[1]; s.close }
    got = nil
    @u.fetch_official(["http://127.0.0.1:#{@p}/a.json", "http://127.0.0.1:#{@p}/b.json"], 22, []) { |k, d| got = [k, d] }
    wait_http(@http) { got }
    assert_equal :error, got[0]
    assert_match(/Không kết nối được kênh cập nhật chính thức.*vẫn hoạt động/m, got[1])
    assert_equal before, installed_version
    assert user_data_intact?
    port
  end

  def test_download_safety_host_truncation_sha
    pkg = make_pkg('1.3.0')
    body = File.binread(pkg)
    mock = MockHTTP.new do |req|
      case req[:path]
      when '/m.json' then [200, {}, official_manifest(pkg)]
      when '/cut.rbz' then [200, { 'X-Truncate' => (body.bytesize / 2).to_s }, body]
      when '/bad.rbz' then [200, {}, body.reverse]
      when '/ok.rbz' then [200, {}, body]
      end
    end
    got = nil
    @u.fetch_official([mock.url('/m.json')], 22, []) { |k, d| got = [k, d] }
    wait_http(@http) { got }
    m = got[1]
    before = installed_version
    dl = lambda do |url, official|
      lm = @u.instance_variable_get(:@last_manifest)
      lm['download_url'] = url
      lm['official'] = official
      res = nil
      @u.download_package(m) { |k, d| res = [k, d] }
      wait_http(@http) { res }
      res
    end
    r = dl.call(mock.url('/ok.rbz'), true)
    assert_equal :error, r[0]
    assert_match(/ngoài kênh chính thức/, r[1], 'kênh chính thức: chỉ nhận host GitHub')
    r = dl.call(mock.url('/cut.rbz'), false)
    assert_equal :error, r[0], 'mất mạng giữa chừng'
    assert_match(/thiếu dữ liệu|kết nối|Tải gói thất bại/i, r[1])
    assert_match(/vẫn hoạt động/, r[1])
    r = dl.call(mock.url('/bad.rbz'), false)
    assert_equal :error, r[0]
    assert_match(/SHA256/, r[1])
    dls = Dir.glob(File.join(@data, 'updates', 'downloads', '*'))
    assert_empty dls, 'không để lại gói lỗi/tải dở'
    assert_equal before, installed_version, 'bản đang chạy không bị động tới'
    r = dl.call(mock.url('/ok.rbz'), false)
    assert_equal :ok, r[0], r.inspect
    info = @u.inspect_package(r[1], su_major: 22)
    type, = run_install(info, 'Cập nhật online')
    assert_equal :install_done, type
    assert_equal '1.3.0', installed_version
    pr = @u.progress
    assert_equal 'Áp dụng phiên bản mới', pr['steps'].last
    assert_match(/Cập nhật thành công/, pr['message'])
    assert user_data_intact?
    # Khôi phục phiên bản trước (bản sao lưu mới nhất)
    last = @u.backups.list.first
    binfo = @u.inspect_backup(last['id'], su_major: 22)
    type, = run_install(binfo, 'Khôi phục phiên bản')
    assert_equal :install_done, type
    assert_equal before, installed_version
    assert user_data_intact?
  ensure
    mock&.close
  end

end
