# frozen_string_literal: true
require 'uri'
require 'json'
require 'cgi'

module MTDesign
  module SmartLibrary
    # Thư viện SketchUp chạy WordPress có REST API công khai (lõi WordPress: /wp-json/wp/v2/posts?search=…,
    # /wp-json/wp/v2/media?include=…). Đã kiểm tra thực tế 25/11/2026: 3 trang dưới đây trả JSON bài viết + ảnh.
    # Chỉ đọc tiêu đề, link, ảnh đại diện. KHÔNG tải tự động: link tải nằm sau trang rút gọn / xác minh chống bot /
    # giỏ hàng — người dùng tự tải trên trang chính thức, plugin nhận file vừa tải và chèn.
    module WpSources
      SITES = {
        'cgtips' => {
          'name' => 'SketchUp CGTips', 'base' => 'https://sketchup.cgtips.org', 'hosts' => %w[sketchup.cgtips.org],
          'img_hosts' => %w[sketchup.cgtips.org], 'domain' => 'cgtips.org', 'lang' => 'en', 'free' => true,
          'license' => 'Miễn phí — theo Terms of Use và Model License Agreement của sketchup.cgtips.org',
          'download_note' => 'Tải trên trang nguồn (link tải + mật khẩu giải nén do trang công bố). Plugin tự nhận file vừa tải và chèn.',
          'zip_passwords' => ['sketchup.cgtips.org']
        },
        'sketchupfree' => {
          'name' => 'SketchupFree', 'base' => 'https://sketchupfree.com', 'hosts' => %w[sketchupfree.com],
          'img_hosts' => %w[img.sketchupfree.com sketchupfree.com], 'domain' => 'sketchupfree.com', 'lang' => 'en', 'free' => true,
          'license' => 'Miễn phí — theo Terms of Service của sketchupfree.com',
          'download_note' => 'Tải trên trang nguồn (trang yêu cầu xác minh chống bot trước khi hiện link). Plugin tự nhận file vừa tải và chèn.',
          'zip_passwords' => []
        },
        'thuviensketchup' => {
          'name' => 'Thư viện SketchUp', 'base' => 'https://thuviensketchup.vn', 'hosts' => %w[thuviensketchup.vn],
          'img_hosts' => %w[thuviensketchup.vn], 'domain' => 'thuviensketchup.vn', 'lang' => 'vi', 'free' => false,
          'license' => 'Trả phí — mua trên thuviensketchup.vn',
          'download_note' => 'Gói trả phí: mua và tải trên trang (link Google Drive sau khi mua). Plugin tự nhận file vừa tải và chèn.',
          'zip_passwords' => []
        }
      }.freeze
      PER_PAGE = 20

      module_function

      # id nguồn có sẵn, hoặc hash nguồn người dùng thêm (đã qua SiteProbe: method wp_rest).
      def site(id)
        return id if id.is_a?(Hash)
        SITES[id.to_s] || raise("Nguồn không hợp lệ: #{id}")
      end

      # Nguồn người dùng → cấu hình giống SITES.
      def from_custom(s)
        u = URI.parse(s['url'])
        host = u.host.downcase
        dom = s['img_domain'].to_s.empty? ? host : s['img_domain'].to_s
        { 'id' => s['id'], 'name' => s['name'], 'base' => "https://#{host}#{u.path.to_s.sub(%r{/+\z}, '')}", 'hosts' => [host],
          'domain' => dom, 'img_hosts' => [host], 'lang' => s['lang'] || 'en', 'free' => nil,
          'license' => 'Theo điều khoản của trang nguồn', 'zip_passwords' => [],
          'download_note' => 'Tải trên trang nguồn. Plugin tự nhận file vừa tải và chèn.' }
      end

      # Host ảnh hợp lệ: danh sách cố định hoặc cùng tên miền (kể cả tên miền con, ví dụ img.<trang>).
      def host_ok?(host, s)
        h = host.to_s.downcase
        return true if s['img_hosts'].include?(h) || s['hosts'].include?(h)
        d = s['domain'].to_s
        !d.empty? && (h == d || h.end_with?(".#{d}"))
      end

      def safe_url_for(url, s)
        u = URI.parse(url.to_s)
        u.is_a?(URI::HTTPS) && host_ok?(u.host, s) ? u.to_s : nil
      rescue URI::InvalidURIError
        nil
      end

      def search_url(id, query, page)
        s = site(id)
        params = { 'search' => Util.utf8(query).strip[0, 100], 'per_page' => PER_PAGE, 'page' => [page.to_i, 1].max,
                   '_fields' => 'id,title,link,featured_media' }
        "#{s['base']}/wp-json/wp/v2/posts?#{URI.encode_www_form(params)}"
      end

      def media_url(id, ids)
        s = site(id)
        ids = ids.map(&:to_i).select(&:positive?).uniq.first(PER_PAGE)
        "#{s['base']}/wp-json/wp/v2/media?#{URI.encode_www_form('include' => ids.join(','), 'per_page' => PER_PAGE, '_fields' => 'id,source_url,media_details')}"
      end

      def safe_https(url, hosts)
        u = URI.parse(url.to_s)
        u.is_a?(URI::HTTPS) && hosts.include?(u.host.to_s.downcase) ? u.to_s : nil
      rescue URI::InvalidURIError
        nil
      end

      def clean_title(html)
        t = CGI.unescapeHTML(Util.utf8(html.to_s).gsub(/<[^>]*>/, ' ')).gsub(/&#8211;|&#8212;/, '–')
        t = t.gsub(/\A\d{3,6}\.\s*/, '') # "21805. Classic …" → "Classic …"
        t.gsub(/\s+/, ' ').strip[0, 160]
      end

      # posts JSON → [{ 'wp_id', 'title', 'link', 'media' }]
      def parse_posts(id, body)
        s = site(id)
        data = JSON.parse(body.to_s)
        raise 'Dữ liệu WordPress không đúng định dạng.' unless data.is_a?(Array)
        data.map do |p|
          next unless p.is_a?(Hash)
          link = safe_url_for(p['link'], s)
          title = clean_title(p['title'].is_a?(Hash) ? p['title']['rendered'] : p['title'])
          next if link.nil? || title.empty? || p['id'].to_i <= 0
          { 'wp_id' => p['id'].to_i, 'title' => title, 'link' => link, 'media' => p['featured_media'].to_i }
        end.compact
      end

      # media JSON → { id => [ảnh nhỏ, ảnh lớn] } (chỉ nhận ảnh từ host của trang).
      def parse_media(id, body)
        s = site(id)
        data = JSON.parse(body.to_s)
        return {} unless data.is_a?(Array)
        data.each_with_object({}) do |m, h|
          next unless m.is_a?(Hash)
          sizes = (m['media_details'].is_a?(Hash) && m['media_details']['sizes'].is_a?(Hash)) ? m['media_details']['sizes'] : {}
          pick = ->(*keys) { keys.map { |k| sizes[k].is_a?(Hash) ? safe_url_for(sizes[k]['source_url'], s) : nil }.compact.first }
          full = safe_url_for(m['source_url'], s)
          small = pick.call('medium_large', 'medium', 'publisher-lg') || full
          large = pick.call('large', '1536x1536', 'medium_large') || full
          h[m['id'].to_i] = [small, large] if small
        end
      rescue JSON::ParserError
        {}
      end
    end
  end
end
