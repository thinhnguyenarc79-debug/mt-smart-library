# frozen_string_literal: true
require 'json'
require 'uri'

module MTDesign
  module SmartLibrary
    # Kiểm tra một website do người dùng thêm có phương thức tìm kiếm hợp lệ không:
    # 1) đọc robots.txt — nếu cấm đường dẫn REST API thì không dùng; 2) thử WordPress REST API lõi (/wp-json/wp/v2/posts?search=).
    # Không đoán endpoint khác, không đọc HTML trang tìm kiếm.
    module SiteProbe
      REST_PATH = '/wp-json/wp/v2/posts'

      module_function

      def robots_url(base)
        u = URI.parse(base)
        "https://#{u.host}/robots.txt"
      end

      # Trả true nếu robots.txt cho phép path với User-agent * (hoặc nhóm khớp tên plugin). Quy tắc Allow/Disallow dài nhất thắng.
      def robots_allow?(text, path, agent = 'MT-Smart-Library-Pro')
        groups = []
        cur = nil
        last_was_agent = false
        text.to_s.each_line do |line|
          l = line.sub(/#.*/, '').strip
          next if l.empty?
          k, v = l.split(':', 2).map { |x| x.to_s.strip }
          case k.downcase
          when 'user-agent'
            unless last_was_agent && cur
              cur = { agents: [], rules: [] }
              groups << cur
            end
            cur[:agents] << v.downcase
            last_was_agent = true
          when 'allow', 'disallow'
            last_was_agent = false
            cur[:rules] << [k.downcase, v] if cur && !v.empty?
          else
            last_was_agent = false
          end
        end
        g = groups.find { |x| x[:agents].any? { |a| a != '*' && agent.downcase.include?(a) } } ||
            groups.find { |x| x[:agents].include?('*') }
        return true unless g
        best = nil
        g[:rules].each do |kind, pat|
          rx = Regexp.new('\A' + Regexp.escape(pat).gsub('\*', '.*').sub(/\\\$\z/, '\z'))
          next unless path =~ rx
          best = [kind, pat.length] if best.nil? || pat.length > best[1] || (pat.length == best[1] && kind == 'allow')
        end
        best.nil? || best[0] == 'allow'
      end

      def registrable(host)
        parts = host.to_s.downcase.split('.')
        return host.to_s.downcase if parts.size <= 2
        if parts[-1].length == 2 && %w[com net org edu gov co ac].include?(parts[-2])
          parts.last(3).join('.')
        else
          parts.last(2).join('.')
        end
      end

      # http: HttpClient-like; done.call(result_hash)
      def probe(http, base, &done)
        u = URI.parse(base)
        site = "https://#{u.host}#{u.path.to_s.sub(%r{/+\z}, '')}"
        http.request(url: robots_url(site), timeout: 15) do |r|
          if r.ok && !robots_allow?(r.body, "#{URI.parse(site).path}#{REST_PATH}")
            next done.call('method' => 'open_only', 'status' => 'blocked',
                           'note' => 'robots.txt của trang không cho phép truy cập tự động REST API — chỉ mở nguồn và nhập link.')
          end
          q = URI.encode_www_form('search' => 'chair', 'per_page' => 1, '_fields' => 'id,title,link,featured_media')
          http.request(url: "#{site}#{REST_PATH}?#{q}", headers: { 'Accept' => 'application/json' }, timeout: 15) do |res|
            done.call(interpret(site, res))
          end
        end
      rescue URI::InvalidURIError
        done.call('method' => 'open_only', 'status' => 'error', 'note' => 'Link không hợp lệ.')
      end

      def interpret(site, res)
        host = URI.parse(site).host.downcase
        if res.ok
          data = begin
            JSON.parse(res.body.to_s)
          rescue JSON::ParserError
            nil
          end
          if data.is_a?(Array)
            title = data.first.is_a?(Hash) && data.first['title'].is_a?(Hash) ? data.first['title']['rendered'].to_s : ''
            vi = host.end_with?('.vn') || title =~ /[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]/i
            return { 'method' => 'wp_rest', 'status' => 'ok', 'lang' => vi ? 'vi' : 'en', 'img_domain' => registrable(host),
                     'note' => 'Tìm kiếm qua WordPress REST API công khai của trang (đã kiểm tra robots.txt).' }
          end
          return { 'method' => 'open_only', 'status' => 'no_api', 'note' => 'Trang không có WordPress REST API công khai — chỉ mở nguồn và nhập link.' }
        end
        if res.code.zero?
          return { 'method' => 'unverified', 'status' => 'error', 'note' => "Không kết nối được trang (#{HttpClient.friendly(res)})." }
        end
        note = [401, 403].include?(res.code) ? "Trang yêu cầu đăng nhập/chặn truy cập tự động (HTTP #{res.code}) — mở nguồn trên trình duyệt và nhập link." :
                 "Trang không có WordPress REST API công khai (HTTP #{res.code}) — chỉ mở nguồn và nhập link."
        { 'method' => 'open_only', 'status' => [401, 403].include?(res.code) ? 'login' : 'no_api', 'note' => note }
      end
    end
  end
end
