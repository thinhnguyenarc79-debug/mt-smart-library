# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

class TestUpdater < Minitest::Test
  def setup
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
end
