# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    module Providers
      # Sketchfab Data API v3 /v3/search (công khai, chính thức). Chạy qua HttpClient (luồng nền).
      class SketchfabProvider < BaseProvider
        def initialize(http, cache, logger = nil)
          super('sketchfab', 'Sketchfab')
          @http = http
          @cache = cache
          @log = logger
          @jobs = {}
        end

        def online?
          true
        end

        def enabled?(settings)
          settings['sources']['sketchfab'] != false
        end

        def applicable?(session, settings)
          return false unless enabled?(settings)
          return false if %w[history local].include?(session.kind) || session.kind == 'favorites'
          !session.online_q.to_s.strip.empty?
        end

        def timeout
          12
        end

        def search(session, cursor, &done)
          downloadable = session.settings['sketchfab']['downloadable_only'] != false
          url = Sketchfab.search_url(session.online_q, cursor: cursor, downloadable: downloadable, count: 24)
          if (hit = @cache.get(url))
            done.call(hit)
            return
          end
          job = @http.request(url: url, headers: { 'Accept' => 'application/json' }, timeout: timeout) do |res|
            @jobs.delete(session.sid)
            out = if res.ok
                    begin
                      d = Sketchfab.parse_search(res.body)
                      v = { 'items' => d['items'].map { |it| normalize(it) }, 'next' => d['next'], 'error' => nil }
                      @cache.put(url, v)
                    rescue StandardError => e
                      { 'items' => [], 'next' => nil, 'error' => "Dữ liệu Sketchfab không đọc được: #{e.message}" }
                    end
                  else
                    msg = res.code > 0 ? Sketchfab.error_message(res.code, res.body) : HttpClient.friendly(res)
                    { 'items' => [], 'next' => nil, 'error' => msg, 'offline' => res.code.zero? }
                  end
            done.call(out)
          end
          @jobs[session.sid] = job
        end

        def cancel(session)
          job = @jobs.delete(session.sid)
          @http.cancel(job) if job
        end

        def normalize(it)
          {
            'source' => 'sketchfab', 'source_label' => 'Sketchfab', 'uid' => it['uid'], 'title' => it['name'],
            'thumb' => it['thumb'], 'thumb_large' => it['thumb_large'] || it['thumb'], 'author' => it['author'],
            'author_url' => it['author_url'], 'license' => it['license'], 'url' => it['viewer_url'],
            'downloadable' => it['downloadable'], 'free' => it['downloadable'], 'insertable' => false,
            'format' => it['formats'].any? { |f| f['type'] == 'source' } ? 'source' : (it['formats'].first || {})['type'],
            'formats' => it['formats'], 'tags' => it['tags'], 'cats' => it['cats'], 'likes' => it['likes'],
            'views' => it['views'], 'faces' => it['faces'], 'age_restricted' => it['age_restricted']
          }
        end

        def status_info(settings)
          super.merge('note' => 'Tích hợp qua Sketchfab Data API chính thức. Tải về cần Sketchfab API token; định dạng glTF/GLB ' \
                                '(không phải SKP) — cần chuyển đổi trước khi dùng trong SketchUp 2022.')
        end
      end

      # Nguồn chưa có phương thức truy cập hợp lệ — chỉ hiển thị giới hạn trong Cài đặt, không tìm kiếm.
      class UnavailableProvider < BaseProvider
        def initialize(id, label, note)
          super(id, label)
          @note = note
        end

        def online?
          true
        end

        def enabled?(_settings)
          false
        end

        def applicable?(_session, _settings)
          false
        end

        def search(_session, _token)
          yield('items' => [], 'next' => nil, 'error' => nil)
        end

        def status_info(_settings)
          { 'id' => id, 'name' => label, 'enabled' => false, 'integrated' => false, 'note' => @note }
        end
      end
    end
  end
end
