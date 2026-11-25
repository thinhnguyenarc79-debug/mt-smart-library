# frozen_string_literal: true
require 'uri'
require 'json'

module MTDesign
  module SmartLibrary
    # Poly Haven API chính thức (https://api.polyhaven.com) — miễn phí cho mọi mục đích, không cần key.
    # Điều kiện: gửi User-Agent riêng (HttpClient::USER_AGENT) và ghi rõ nguồn "Poly Haven" trên giao diện.
    # Model CC0, tải định dạng glTF + texture → bộ đọc glTF tích hợp chèn thẳng vào SketchUp.
    module PolyHaven
      API = 'https://api.polyhaven.com'
      CATALOG_URL = "#{API}/assets?type=models"
      THUMB_HOSTS = %w[cdn.polyhaven.com].freeze
      FILE_HOSTS = %w[dl.polyhaven.org].freeze
      RES_ORDER = %w[2k 1k 4k].freeze
      MAX_TOTAL = 400 * 1_048_576

      module_function

      def valid_id?(id)
        id.is_a?(String) && id =~ /\A[A-Za-z0-9_\-]{1,80}\z/ ? true : false
      end

      def files_url(id)
        raise "Mã model Poly Haven không hợp lệ: #{id}" unless valid_id?(id)
        "#{API}/files/#{id}"
      end

      def page_url(id)
        "https://polyhaven.com/a/#{id}"
      end

      def safe_https(url, hosts)
        u = URI.parse(url.to_s)
        u.is_a?(URI::HTTPS) && hosts.include?(u.host.to_s.downcase) ? u.to_s : nil
      rescue URI::InvalidURIError
        nil
      end

      # /assets?type=models → mảng model đã chuẩn hóa (bỏ mục thiếu dữ liệu).
      def parse_catalog(body)
        data = JSON.parse(body.to_s)
        raise 'Dữ liệu Poly Haven không đúng định dạng.' unless data.is_a?(Hash)
        data.map do |id, a|
          next unless valid_id?(id) && a.is_a?(Hash)
          next unless a['type'].nil? || a['type'].to_i == 2
          {
            'id' => id, 'name' => Util.utf8(a['name'] || id).strip, 'tags' => Array(a['tags']).map { |t| Util.utf8(t) },
            'categories' => Array(a['categories']).map { |t| Util.utf8(t) }, 'category' => Util.utf8(a['category'].to_s),
            'authors' => a['authors'].is_a?(Hash) ? a['authors'].keys.map { |x| Util.utf8(x) } : [],
            'polycount' => a['polycount'].to_i, 'downloads' => a['download_count'].to_i,
            'thumb' => safe_https(a['thumbnail_url'], THUMB_HOSTS), 'published' => a['date_published'].to_i
          }
        end.compact
      end

      # /files/{id} → file glTF chính + các file đi kèm (bin, texture) ở độ phân giải ưu tiên.
      def pick_gltf(body, prefer: '2k')
        data = JSON.parse(body.to_s)
        g = data.is_a?(Hash) ? data['gltf'] : nil
        raise 'Model này không có bản glTF trên Poly Haven.' unless g.is_a?(Hash)
        order = ([prefer] + RES_ORDER).uniq
        res = order.find { |r| g[r].is_a?(Hash) && g[r]['gltf'].is_a?(Hash) }
        raise 'Model này không có bản glTF trên Poly Haven.' unless res
        main = g[res]['gltf']
        murl = safe_https(main['url'], FILE_HOSTS)
        raise 'Link tải Poly Haven không hợp lệ.' unless murl
        files = [{ 'rel' => File.basename(URI.parse(murl).path), 'url' => murl, 'size' => main['size'].to_i, 'md5' => main['md5'].to_s }]
        (main['include'] || {}).each do |rel, f|
          next unless f.is_a?(Hash)
          r = safe_rel(rel)
          u = safe_https(f['url'], FILE_HOSTS)
          raise "File đi kèm không an toàn: #{rel}" unless r && u
          files << { 'rel' => r, 'url' => u, 'size' => f['size'].to_i, 'md5' => f['md5'].to_s }
        end
        total = files.sum { |f| f['size'] }
        raise 'Model quá lớn (trên 400 MB).' if total > MAX_TOTAL
        { 'resolution' => res, 'files' => files, 'total' => total }
      end

      # Đường dẫn tương đối an toàn (không tuyệt đối, không "..", chỉ ký tự thường gặp).
      def safe_rel(rel)
        r = rel.to_s.tr('\\', '/')
        return nil if r.empty? || r.start_with?('/') || r =~ /\A[A-Za-z]:/ || r.length > 200
        parts = r.split('/')
        return nil if parts.any? { |p| p.empty? || p == '.' || p == '..' || p !~ /\A[A-Za-z0-9_\-. ]+\z/ }
        r
      end

      def attribution(item, res)
        "#{item['title']}\nNguồn: Poly Haven (#{item['url']})\nTác giả: #{item['author']}\n" \
          "Giấy phép: CC0 (public domain)\nĐộ phân giải texture: #{res}\n"
      end
    end
  end
end
