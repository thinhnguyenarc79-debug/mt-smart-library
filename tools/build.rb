# frozen_string_literal: true
# Đóng gói MT SMART LIBRARY PRO:  ruby tools/build.rb
# - Kiểm tra cú pháp Ruby (ruby -wc) và JS (node --check nếu có)
# - Kiểm tra phiên bản đồng bộ (version.rb <-> update_manifest.json)
# - Tạo RBZ (mt_smart_library.rb + mt_smart_library/ ngay ở gốc, không thêm cấp thư mục)
# - Tự kiểm tra RBZ bằng chính Updater.inspect_package
# - Sinh dist/update_manifest.json (sha256, size) để phát hành online
Encoding.default_external = Encoding::UTF_8
require 'json'
require 'digest'
require 'fileutils'
require 'open3'

ROOT = File.expand_path('..', __dir__)
SRC = File.join(ROOT, 'src')
DIST = File.join(ROOT, 'dist')
CODE = File.join(SRC, 'mt_smart_library')

def die(msg)
  warn "BUILD LỖI: #{msg}"
  exit 1
end

ver_src = File.read(File.join(CODE, 'updater', 'version.rb'))
VERSION_STR = ver_src[/VERSION = '([^']+)'/, 1] || die('Không đọc được VERSION')
PLUGIN = ver_src[/PLUGIN_ID = '([^']+)'/, 1]
manifest = JSON.parse(File.read(File.join(CODE, 'updater', 'update_manifest.json')))
die("update_manifest.json version #{manifest['version']} ≠ #{VERSION_STR}") unless manifest['version'] == VERSION_STR
die('update_manifest.json plugin_id sai') unless manifest['plugin_id'] == PLUGIN
loader = File.read(File.join(SRC, 'mt_smart_library.rb'))
die('Loader phải lấy VERSION từ updater/version.rb') unless loader.include?("'updater', 'version'") && loader.include?('ext.version = VERSION')

rb = Dir.glob(File.join(SRC, '**', '*.rb'))
rb.each do |f|
  out, st = Open3.capture2e('ruby', '-wc', f)
  die("#{f}: #{out}") unless st.success? && !out.include?('warning')
end
js = Dir.glob(File.join(SRC, '**', '*.js'))
if system('node --version > /dev/null 2>&1')
  js.each { |f| out, st = Open3.capture2e('node', '--check', f); die("#{f}: #{out}") unless st.success? }
end
Dir.glob(File.join(SRC, '**', '*.json')).each { |f| JSON.parse(File.read(f)) }
Dir.glob(File.join(SRC, '**', '__pycache__')).each { |d| FileUtils.rm_rf(d) } # bytecode sinh ra khi chạy test
Dir.glob(File.join(SRC, '**', '*.py')).each do |f|
  out, st = Open3.capture2e('python3', '-c', 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())', f)
  die("#{f}: #{out}") unless st.success?
end
junk = Dir.glob(File.join(SRC, '**', '{.DS_Store,Thumbs.db,*.bak,*.tmp*,*~}'), File::FNM_DOTMATCH)
die("Có file rác trong src: #{junk.join(', ')}") unless junk.empty?

FileUtils.mkdir_p(DIST)
rbz = File.join(DIST, "MT_SMART_LIBRARY_PRO_v#{VERSION_STR}.rbz")
File.delete(rbz) if File.exist?(rbz)
out, st = Open3.capture2e('zip', '-r', '-X', '-9', '-q', rbz, 'mt_smart_library.rb', 'mt_smart_library', chdir: SRC)
die("zip: #{out}") unless st.success?

# Tự kiểm tra gói bằng chính bộ kiểm tra của updater
module MTDesign; module SmartLibrary; end; end
%w[updater/version core/util core/paths core/logger net/http_client updater/zip_reader updater/backup_manager updater/updater].each do |f|
  require File.join(CODE, f)
end
SLB = MTDesign::SmartLibrary
tmp = File.join(DIST, '.verify')
FileUtils.rm_rf(tmp)
u = SLB::Updater.new(logger: nil, http: nil, plugins_root: File.join(tmp, 'Plugins'), data_root: File.join(tmp, 'Data'))
info = u.inspect_package(rbz, su_major: 22)
die('RBZ không có cấu trúc gốc phẳng') unless info['prefix'] == ''
die('RBZ sai phiên bản') unless info['version'] == VERSION_STR
die("RBZ không tương thích SketchUp 2022: #{info['compat_message']}") unless info['compatible']
names = SLB::ZipReader.new(rbz).entries.map(&:name)
die('RBZ chứa file ngoài plugin') unless names.all? { |n| n == 'mt_smart_library.rb' || n.start_with?('mt_smart_library/') }
FileUtils.rm_rf(tmp)

sha = Digest::SHA256.file(rbz).hexdigest
release = manifest.merge('download_url' => '', 'sha256' => sha, 'size' => File.size(rbz),
                         '_huong_dan' => 'Điền download_url (https) của file RBZ sau khi tải lên GitHub Releases/máy chủ, rồi đính kèm file này với tên update_manifest.json.')
File.write(File.join(DIST, 'update_manifest.json'), JSON.pretty_generate(release))
puts "RBZ: #{rbz}"
puts "  #{names.size} mục, #{File.size(rbz)} byte, sha256 #{sha}"
puts "  PLUGIN_ID #{PLUGIN} · VERSION #{VERSION_STR} · #{rb.size} file Ruby · #{js.size} file JS — kiểm tra OK"
