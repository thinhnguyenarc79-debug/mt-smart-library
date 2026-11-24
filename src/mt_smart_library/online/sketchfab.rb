# frozen_string_literal: true
require 'uri'
require 'json'

module MTDesign
  module SmartLibrary
    # Sketchfab Data API v3 (endpoint /v3/search công khai) và Download API (cần đăng nhập Sketchfab).
    # Download API chỉ cung cấp glTF / GLB / USDZ (đôi khi "source") — KHÔNG phải SKP.
    module Sketchfab
      API = 'https://api.sketchfab.com/v3'
      THUMB_HOSTS = %w[media.sketchfab.com].freeze
      SAFE_LINK_HOSTS = %w[sketchfab.com www.sketchfab.com].freeze
      FORMATS = %w[source gltf glb usdz].freeze

      module_function

      def search_url(query, cursor: nil, downloadable: true, count: 24)
        q = Util.utf8(query).strip
        raise 'Nhập từ khóa để tìm trên Sketchfab.' if q.empty?
        params = { 'type' => 'models', 'q' => q[0, 200], 'count' => [[count.to_i, 1].max, 24].min }
        params['downloadable'] = 'true' if downloadable
        params['cursor'] = cursor.to_s if cursor && cursor.to_s =~ /\A[A-Za-z0-9_\-=]{1,64}\z/
        "#{API}/search?#{URI.encode_www_form(params)}"
      end

      def auth_header(token, type)
        t = token.to_s.strip
        raise 'Chưa có Sketchfab token. Nhập trong Cài đặt > Sketchfab.' if t.empty?
        type.to_s == 'bearer' ? "Bearer #{t}" : "Token #{t}"
      end

      def safe_https(url, hosts)
        u = URI.parse(url.to_s)
        return nil unless u.is_a?(URI::HTTPS) && hosts.include?(u.host.to_s.downcase)
        u.to_s
      rescue URI::InvalidURIError
        nil
      end

      def pick_thumb(images, target = 480)
        imgs = Array(images).select { |i| i.is_a?(Hash) && safe_https(i['url'], THUMB_HOSTS) }
        return nil if imgs.empty?
        best = imgs.min_by { |i| (i['width'].to_i - target).abs }
        safe_https(best['url'], THUMB_HOSTS)
      end

      def parse_search(body)
        data = JSON.parse(body.to_s)
        raise 'Phản hồi Sketchfab không đúng định dạng.' unless data.is_a?(Hash) && data['results'].is_a?(Array)
        items = data['results'].map do |r|
          next unless r.is_a?(Hash) && r['uid'].to_s =~ /\A[0-9a-f]{32}\z/
          user = r['user'].is_a?(Hash) ? r['user'] : {}
          lic = r['license'].is_a?(Hash) ? r['license'] : {}
          archives = r['archives'].is_a?(Hash) ? r['archives'] : {}
          {
            'uid' => r['uid'],
            'name' => Util.utf8(r['name']).strip[0, 200],
            'author' => Util.utf8(user['displayName'] || user['username']).strip[0, 120],
            'author_url' => safe_https(user['profileUrl'], SAFE_LINK_HOSTS),
            'license' => Util.utf8(lic['label']).strip[0, 120],
            'thumb' => pick_thumb(r.dig('thumbnails', 'images')),
            'thumb_large' => pick_thumb(r.dig('thumbnails', 'images'), 1024),
            'tags' => Array(r['tags']).map { |t| t.is_a?(Hash) ? (t['name'] || t['slug']).to_s : t.to_s }.reject(&:empty?).first(30),
            'cats' => Array(r['categories']).flat_map { |c| c.is_a?(Hash) ? [c['slug'], c['name']] : [c] }.compact.map { |c| c.to_s.downcase }.uniq,
            'likes' => r['likeCount'].to_i,
            'views' => r['viewCount'].to_i,
            'age_restricted' => r['isAgeRestricted'] == true,
            'viewer_url' => safe_https(r['viewerUrl'], SAFE_LINK_HOSTS) || "https://sketchfab.com/3d-models/#{r['uid']}",
            'downloadable' => r['isDownloadable'] == true,
            'faces' => r['faceCount'].to_i,
            'formats' => FORMATS.select { |f| archives[f].is_a?(Hash) }.map { |f| { 'type' => f, 'size' => archives[f]['size'].to_i } }
          }
        end.compact
        cur = data['cursors'].is_a?(Hash) ? data['cursors'] : {}
        { 'items' => items, 'next' => cur['next'] && cur['next'].to_s, 'previous' => cur['previous'] && cur['previous'].to_s }
      end

      def download_url(uid)
        raise 'UID không hợp lệ.' unless uid.to_s =~ /\A[0-9a-f]{32}\z/
        "#{API}/models/#{uid}/download"
      end

      # Trả {'gltf'=>{'url','size','expires'}, ...} chỉ với URL https hợp lệ.
      def parse_download(body)
        data = JSON.parse(body.to_s)
        raise 'Phản hồi tải không hợp lệ.' unless data.is_a?(Hash)
        out = {}
        FORMATS.each do |f|
          v = data[f]
          next unless v.is_a?(Hash)
          u = URI.parse(v['url'].to_s) rescue nil # rubocop:disable Style/RescueModifier
          next unless u.is_a?(URI::HTTPS)
          out[f] = { 'url' => u.to_s, 'size' => v['size'].to_i, 'expires' => v['expires'].to_i }
        end
        out
      end

      def error_message(code, body)
        detail = begin
          j = JSON.parse(body.to_s)
          j.is_a?(Hash) ? (j['detail'] || j['error'] || j['message']).to_s : ''
        rescue StandardError
          ''
        end
        base = case code
               when 401 then 'Sketchfab từ chối token (401). Kiểm tra lại API token / loại token.'
               when 403 then 'Model này không cho phép tải qua API hoặc tài khoản chưa đủ quyền (403).'
               when 404 then 'Không tìm thấy model (404).'
               when 429 then 'Sketchfab giới hạn tần suất (429). Đợi một lát rồi thử lại.'
               else "Sketchfab lỗi HTTP #{code}."
               end
        detail.empty? ? base : "#{base} #{detail[0, 200]}"
      end

      def extension_for(format, url)
        path = URI.parse(url).path.to_s
        ext = File.extname(path).downcase
        return ext if ext =~ /\A\.[a-z0-9]{2,5}\z/
        { 'gltf' => '.zip', 'glb' => '.glb', 'usdz' => '.usdz', 'source' => '.zip' }[format] || '.bin'
      rescue StandardError
        '.bin'
      end

      def attribution(item, format)
        <<~TXT
          Model: #{item['name']}
          Tác giả: #{item['author']} #{item['author_url']}
          Giấy phép: #{item['license']}
          Nguồn: #{item['viewer_url']}
          Định dạng tải: #{format}
          Tải qua Sketchfab Download API bằng MT SMART LIBRARY PRO #{VERSION} ngày #{Time.now.strftime('%d/%m/%Y %H:%M')}.
          Lưu ý: Model được cung cấp bởi Sketchfab. Tuân thủ giấy phép trên (ghi công tác giả và Sketchfab khi giấy phép yêu cầu).
        TXT
      end
    end
  end
end
