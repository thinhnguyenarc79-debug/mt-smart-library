# frozen_string_literal: true
require 'json'
require 'uri'
require 'securerandom'

module MTDesign
  module SmartLibrary
    # SMART SOURCE MANAGER — danh sách nguồn do người dùng quản lý (thêm/sửa/xóa/bật/tắt, xuất/nhập JSON).
    # Lưu ở <dữ liệu>/sources.json (không nằm trong mã plugin, không mất khi cập nhật).
    # Nguồn có sẵn (đã tích hợp API/REST đã kiểm chứng) được trộn vào danh sách nhưng không xóa được, chỉ bật/tắt.
    class SourceRegistry
      TYPES = {
        'website' => 'Website', 'facebook_group' => 'Facebook Group', 'facebook_page' => 'Facebook Fanpage',
        'gdrive' => 'Google Drive', 'mediafire' => 'MediaFire', 'mega' => 'Mega', 'dropbox' => 'Dropbox',
        'onedrive' => 'OneDrive', 'local' => 'Thư mục máy tính'
      }.freeze
      # Phương thức truy cập thực tế plugin hỗ trợ.
      METHODS = {
        'api' => 'API chính thức', 'wp_rest' => 'WordPress REST API công khai', 'local' => 'Đọc thư mục máy tính',
        'sitemap' => 'Web crawler theo sitemap (tuân thủ robots.txt)', 'gdrive' => 'Google Drive API (API key)',
        'index' => 'Chỉ mục máy tìm kiếm (Tavily / Serper / SerpApi / Brave / SearXNG)',
        'manual' => 'Lưu bài đang xem (đăng nhập thủ công)',
        'direct_link' => 'Link tải trực tiếp (nhập link)', 'open_only' => 'Mở nguồn + nhập link thủ công',
        'unverified' => 'Chưa xác minh'
      }.freeze
      NOTES = {
        'facebook_group' => 'Groups API đã bị Meta gỡ (22/04/2024). Đồng bộ = tìm bài CÔNG KHAI đã được máy tìm kiếm lập chỉ mục ' \
                            '(Tavily không cần key). Nhóm kín: “Đăng nhập & lưu bài” — bạn tự đăng nhập, bấm lưu bài đang xem.',
        'facebook_page' => 'Đồng bộ = tìm bài công khai đã được lập chỉ mục. Hoặc “Đăng nhập & lưu bài” để lưu bài đang xem.',
        'gdrive' => 'Mở thư mục trên trình duyệt; tải file về, plugin tự nhận file vừa tải (hoặc dán link file).',
        'mediafire' => 'Trang tải có quảng cáo/xác minh — mở trên trình duyệt, plugin tự nhận file vừa tải.',
        'mega' => 'File Mega được mã hóa phía trình duyệt — mở trên trình duyệt, plugin tự nhận file vừa tải.',
        'dropbox' => 'Link chia sẻ Dropbox tải trực tiếp được (dl=1, theo hướng dẫn chính thức của Dropbox).',
        'onedrive' => 'Mở trên trình duyệt, plugin tự nhận file vừa tải.'
      }.freeze
      MAX = 300

      attr_reader :path

      def initialize(path, builtins: [])
        @path = path
        @builtins = builtins
        @items = load
      end

      def custom
        @items
      end

      # Danh sách đầy đủ cho giao diện: nguồn có sẵn + nguồn người dùng.
      def list(builtin_state = {})
        @builtins.map { |b| b.merge('builtin' => true).merge(builtin_state[b['id']] || {}) } + @items.map(&:dup)
      end

      def find(id)
        @items.find { |s| s['id'] == id.to_s }
      end

      def enabled_wp
        @items.select { |s| s['enabled'] && s['method'] == 'wp_rest' }
      end

      def add(o)
        s = normalize(o)
        raise 'Đã có nguồn với link này.' if @items.any? { |x| x['url'] == s['url'] && x['type'] == s['type'] }
        raise "Tối đa #{MAX} nguồn." if @items.size >= MAX
        s['id'] = 'u_' + SecureRandom.hex(5)
        s['added'] = Time.now.to_i
        @items << s
        save
        s
      end

      def update(id, o)
        s = find(id) || raise('Không tìm thấy nguồn.')
        n = normalize(s.merge(o.select { |k, _| %w[name type url enabled].include?(k) }))
        url_changed = n['url'] != s['url'] || n['type'] != s['type']
        n['name_auto'] = false if o.key?('name') && o['name'].to_s.strip != s['name'] # người dùng tự đặt tên → giữ
        s.merge!(n)
        if url_changed
          s['method'] = default_method(s['type'])
          s['status'] = 'unchecked'
        end
        save
        s
      end

      def set_status(id, h)
        s = find(id)
        return unless s
        s.merge!(h.select { |k, _| %w[method status note img_domain checked lang sitemaps].include?(k) })
        s['checked'] = Time.now.to_i
        save
      end

      # Tên thật học được (tiêu đề nhóm Facebook) — chỉ thay khi tên đang là tên tự đặt (người dùng chưa sửa).
      def rename_auto(id, name)
        s = find(id)
        name = Util.utf8(name.to_s).strip[0, 80]
        return false unless s && !name.empty? && auto_name?(s) && s['name'] != name
        s['name'] = name
        s['name_auto'] = true
        save
        true
      end

      def auto_name?(s)
        s['name_auto'] == true || s['name'].to_s =~ /\A((www|m|web)\.)?(facebook|fb)\.com\z/i
      end

      def self.fb_default_name(url)
        parts = URI.parse(url).path.to_s.split('/').reject(&:empty?)
        parts[0] == 'groups' && parts[1] ? "Nhóm Facebook #{parts[1]}" : "Facebook #{parts[0] || ''}".strip
      rescue URI::InvalidURIError
        'Facebook'
      end

      def toggle(id, on)
        s = find(id)
        return unless s
        s['enabled'] = on ? true : false
        save
      end

      def delete(id)
        n = @items.size
        @items.reject! { |s| s['id'] == id.to_s }
        save if @items.size != n
      end

      def export_json
        JSON.pretty_generate('format' => 'mt-smart-library-sources', 'version' => 1, 'exported' => Time.now.to_i,
                             'sources' => @items.map { |s| s.slice('name', 'type', 'url', 'enabled') })
      end

      # Nhập: chỉ nhận trường an toàn; bỏ trùng; trả số nguồn đã thêm.
      def import_json(text)
        d = JSON.parse(text.to_s)
        list = d.is_a?(Hash) ? d['sources'] : d
        raise 'File không đúng định dạng danh sách nguồn.' unless list.is_a?(Array)
        added = 0
        list.first(MAX).each do |o|
          next unless o.is_a?(Hash)
          begin
            add(o)
            added += 1
          rescue StandardError
            next
          end
        end
        added
      rescue JSON::ParserError
        raise 'File JSON không hợp lệ.'
      end

      def normalize(o)
        type = TYPES.key?(o['type'].to_s) ? o['type'].to_s : 'website'
        url = o['url'].to_s.strip
        if type == 'local'
          raise 'Thư mục không tồn tại.' unless File.directory?(url)
          url = Util.norm_path(url)
        else
          url = "https://#{url}" unless url =~ %r{\Ahttps?://}i
          u = URI.parse(url)
          raise 'Link không hợp lệ.' unless u.is_a?(URI::HTTP) && u.host.to_s.include?('.')
          u.scheme = 'https' if u.scheme == 'http'
          url = u.to_s.sub(%r{/+\z}, '')
          type = detect_type(u) if type == 'website' && o['type'].to_s.empty?
        end
        name = Util.utf8(o['name'].to_s).strip
        auto = name.empty? ? true : o['name_auto'] == true
        if name.empty?
          name = if type == 'local' then File.basename(url)
                 elsif type.start_with?('facebook') then self.class.fb_default_name(url)
                 else URI.parse(url).host.sub(/\Awww\./, '')
                 end
        end
        { 'name' => name[0, 80], 'type' => type, 'url' => url, 'enabled' => o.key?('enabled') ? o['enabled'] != false : true,
          'method' => o['method'] && METHODS.key?(o['method']) ? o['method'] : default_method(type),
          'status' => o['status'] || 'unchecked', 'name_auto' => auto }
      rescue URI::InvalidURIError
        raise 'Link không hợp lệ.'
      end

      def detect_type(u)
        self.class.detect_type(u)
      end

      def self.detect_type(u)
        h = u.host.to_s.downcase
        p = u.path.to_s
        return(p.include?('/groups/') ? 'facebook_group' : 'facebook_page') if h =~ /(\A|\.)facebook\.com\z|(\A|\.)fb\.com\z/
        return 'gdrive' if h =~ /(\A|\.)drive\.google\.com\z|\Adocs\.google\.com\z/
        return 'mediafire' if h =~ /(\A|\.)mediafire\.com\z/
        return 'mega' if h =~ /(\A|\.)mega\.(nz|io)\z/
        return 'dropbox' if h =~ /(\A|\.)dropbox\.com\z/
        return 'onedrive' if h =~ /(\A|\.)(onedrive\.live\.com|1drv\.ms|sharepoint\.com)\z/
        'website'
      end

      def default_method(type)
        case type
        when 'local' then 'local'
        when 'dropbox' then 'direct_link'
        when 'website' then 'unverified'
        when 'facebook_group', 'facebook_page' then 'index'
        else 'open_only'
        end
      end

      private

      def load
        return [] unless File.file?(@path)
        d = JSON.parse(File.read(@path, encoding: 'UTF-8'))
        list = d.is_a?(Hash) ? Array(d['sources']) : []
        list = list.select { |s| s.is_a?(Hash) && s['id'].to_s =~ /\Au_[0-9a-f]{10}\z/ && TYPES.key?(s['type']) }.first(MAX)
        list.each do |s| # V1.0.13: nhóm Facebook cũ đều tên “facebook.com” → tên theo mã nhóm (thay bằng tên thật khi biết)
          next unless s['type'].to_s.start_with?('facebook')
          if auto_name?(s)
            s['name'] = self.class.fb_default_name(s['url'])
            s['name_auto'] = true
          end
          s['method'] = 'index' if %w[open_only unverified].include?(s['method'])
        end
        list
      rescue StandardError
        []
      end

      def save
        Util.atomic_write(@path, JSON.generate('version' => 1, 'sources' => @items))
      end
    end
  end
end
