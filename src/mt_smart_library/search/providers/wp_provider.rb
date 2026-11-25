# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    module Providers
      # Một trang thư viện WordPress (xem WpSources). Mỗi đợt: 1 lần gọi /posts?search= + 1 lần /media?include=
      # để lấy ảnh. Kết quả hiển thị nút XEM: mở trang tải chính thức; file người dùng tải về được plugin tự nhận.
      class WpProvider < BaseProvider
        # site_id: id nguồn có sẵn, hoặc hash cấu hình (nguồn người dùng thêm).
        def initialize(site_id, http, cache, logger = nil)
          @site = WpSources.site(site_id)
          super(site_id.is_a?(Hash) ? @site['id'] : site_id, @site['name'])
          @http = http
          @cache = cache
          @log = logger
          @jobs = {}
        end

        def online?
          true
        end

        def enabled?(settings)
          return @site['enabled'] != false if @site['custom'] # nguồn người dùng: bật/tắt lưu trong sources.json
          settings['sources'][id] != false
        end

        def site
          @site
        end

        def applicable?(session, settings)
          return false unless enabled?(settings)
          return false if %w[history local favorites].include?(session.kind)
          !query_text(session).strip.empty?
        end

        # Trang tiếng Việt: tìm bằng từ khóa gốc; trang tiếng Anh: bằng từ khóa đã dịch.
        def query_text(session)
          if @site['lang'] == 'vi' && session.query && !session.query.empty?
            session.query.raw.to_s
          else
            session.online_q.to_s
          end
        end

        # Lọc liên quan bằng truy vấn gốc (có cả từ Việt lẫn bản dịch Anh) để giữ tiêu đề tiếng Việt.
        def relevance_query(session)
          session.query && !session.query.empty? ? session.query : session.oquery
        end

        def search(session, token, &done)
          page = (token || 1).to_i
          url = WpSources.search_url(@site, query_text(session), page)
          if (hit = @cache.get(url))
            done.call(hit)
            return
          end
          @jobs[session.sid] = @http.request(url: url, headers: { 'Accept' => 'application/json' }, timeout: 15) do |res|
            if res.ok
              begin
                posts = WpSources.parse_posts(@site, res.body)
                with_media(session, posts) do |imgs|
                  items = posts.map { |p| normalize(p, imgs[p['media']]) }
                  out = { 'items' => items, 'next' => posts.size >= WpSources::PER_PAGE ? page + 1 : nil, 'error' => nil }
                  @cache.put(url, out)
                  done.call(out)
                end
              rescue StandardError => e
                done.call('items' => [], 'next' => nil, 'error' => "#{label}: dữ liệu không đọc được (#{e.message})")
              end
            elsif res.code == 400 && page > 1
              done.call('items' => [], 'next' => nil, 'error' => nil) # hết trang
            else
              msg = res.code > 0 ? "#{label} trả lỗi HTTP #{res.code}." : HttpClient.friendly(res)
              done.call('items' => [], 'next' => nil, 'error' => msg, 'offline' => res.code.zero?)
            end
          end
        end

        def cancel(session)
          job = @jobs.delete(session.sid)
          @http.cancel(job) if job
        end

        def normalize(p, img)
          {
            'source' => id, 'source_label' => label, 'uid' => "#{id}-#{p['wp_id']}", 'title' => p['title'],
            'thumb' => img && img[0], 'thumb_large' => img && img[1], 'author' => label, 'license' => @site['license'],
            'url' => p['link'], 'downloadable' => false, 'web_only' => true, 'download_note' => @site['download_note'],
            'free' => @site['free'] ? true : false, 'insertable' => false, 'format' => 'skp', 'formats' => [{ 'type' => 'skp' }],
            'tags' => [], 'cats' => []
          }
        end

        def status_info(settings)
          super.merge('note' => "WordPress REST API công khai của #{@site['base'].sub('https://', '')}: tìm kiếm + ảnh. " \
                                "#{@site['download_note']}")
        end

        private

        def with_media(session, posts)
          ids = posts.map { |p| p['media'] }.select(&:positive?)
          return yield({}) if ids.empty?
          @jobs[session.sid] = @http.request(url: WpSources.media_url(@site, ids), headers: { 'Accept' => 'application/json' },
                                             timeout: 15) do |res|
            yield(res.ok ? WpSources.parse_media(@site, res.body) : {}) # thiếu ảnh vẫn hiện kết quả
          end
        end
      end
    end
  end
end
