# frozen_string_literal: true
# Kiểm tra đường cập nhật thực tế: bản CŨ (giải nén từ RBZ cũ) dùng chính updater của nó để cài RBZ MỚI.
#   ruby tools/verify_upgrade.rb dist/OLD.rbz dist/NEW.rbz
Encoding.default_external = Encoding::UTF_8
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

old_rbz, new_rbz = ARGV.map { |f| File.expand_path(f) }
abort 'Cần 2 tham số: RBZ cũ và RBZ mới' unless old_rbz && new_rbz && File.file?(old_rbz) && File.file?(new_rbz)
tmp = Dir.mktmpdir('upgrade_')
plugins = File.join(tmp, 'Plugins')
data = File.join(tmp, 'Data')
FileUtils.mkdir_p([plugins, File.join(data, 'thumbs')])
_o, st = Open3.capture2e('unzip', '-q', old_rbz, '-d', plugins)
abort 'unzip lỗi' unless st.success?
user_files = {
  'settings.json' => JSON.generate('schema' => 2, 'roots' => ['D:/Thư viện SKP'], 'favorites' => ['f' * 64], 'history' => ['e' * 64],
                                   'ai' => { 'model' => 'gpt-6-luna', 'remember_key' => true }),
  'index_cache.json' => '{"schema":2,"dirs":{"D:/Thư viện SKP":{"m":1,"f":[["Ghế.skp",1,1]],"d":[]}}}',
  'thumbs/abc_1_1.png' => 'PNG', 'secrets/openai.dpapi' => 'ENCRYPTED-BLOB'
}
user_files.each { |rel, c| f = File.join(data, rel); FileUtils.mkdir_p(File.dirname(f)); File.write(f, c) }

module MTDesign; module SmartLibrary; end; end
code = File.join(plugins, 'mt_smart_library')
%w[updater/version core/util core/paths core/logger net/http_client updater/zip_reader updater/backup_manager updater/updater].each do |f|
  require File.join(code, f) # nạp MÃ CỦA BẢN CŨ
end
SLV = MTDesign::SmartLibrary
ver = ->(dir) { File.read(File.join(dir, 'mt_smart_library', 'updater', 'version.rb'))[/VERSION = '([^']+)'/, 1] }
old_v = ver.call(plugins)
log = SLV::Logger.new(File.join(data, 'logs', 'mt.log'))
u = SLV::Updater.new(logger: log, http: nil, plugins_root: plugins, data_root: data)
run = lambda do |info, reason|
  u.start_install(info, reason)
  u.thread.join(60)
  u.events.last
end
info = u.inspect_package(new_rbz, su_major: 22)
puts "Bản đang cài: #{old_v} (updater của #{SLV::VERSION}) → gói: #{info['version']} [#{info['relation']}] #{info['compat_message']}"
abort 'Gói mới không được nhận là bản mới hơn' unless info['relation'] == 'newer' && info['compatible']
type, payload = run.call(info, 'Cập nhật từ file')
abort "Cài thất bại: #{payload.inspect}" unless type == :install_done
new_v = ver.call(plugins)
abort "Sau cài vẫn là #{new_v}" unless new_v == info['version']
intact = user_files.all? { |rel, c| File.read(File.join(data, rel)) == c }
abort 'Dữ liệu người dùng bị thay đổi!' unless intact
abort 'Có loader trùng' unless Dir.glob(File.join(plugins, '*.rb')).size == 1
abort 'Còn thư mục tạm' unless Dir.glob(File.join(plugins, '*__*')).empty?
puts "✓ Cập nhật #{old_v} → #{new_v} bằng updater của bản cũ; dữ liệu người dùng (#{user_files.size} file) giữ nguyên; không trùng loader."
backup = u.backups.list.first
rinfo = u.inspect_backup(backup['id'], su_major: 22)
type, = run.call(rinfo, 'Khôi phục phiên bản')
abort 'Khôi phục thất bại' unless type == :install_done && ver.call(plugins) == old_v
abort 'Dữ liệu người dùng bị thay đổi khi khôi phục!' unless user_files.all? { |rel, c| File.read(File.join(data, rel)) == c }
puts "✓ Khôi phục về #{old_v} thành công; dữ liệu người dùng giữ nguyên."
puts 'UPGRADE_PATH_PASS'
