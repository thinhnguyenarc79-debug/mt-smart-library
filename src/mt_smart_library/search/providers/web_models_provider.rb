# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    module Providers
      # Tìm model trên 3D Warehouse, 3dsky, 3DBox, Sketch Shaper, Tài liệu kiến trúc, SketchUp.vn
      # thông qua công cụ tìm kiếm web đã cấu hình (Tavily không cần key; Serper/SerpApi/Brave/SearXNG nếu có).
      # Mọi website chạy SONG SONG (HttpClient luồng nền), kết quả đổ dần về lưới. Chỉ giữ link CHI TIẾT model;
      # ảnh đại diện lấy từ nhà cung cấp tìm kiếm hoặc thẻ og:image công khai của trang chi tiết (tôn trọng robots.txt).
      class WebModelsProvider < BaseProvider
        DELAY = 0.8          # chờ người dùng gõ xong rồi mới gọi công cụ tìm kiếm (tiết kiệm hạn mức)
        MAX_THUMBS = 36
        THUMB_PARALLEL = 6
        PAGE_MAX = 1_500_000
        IMG_MAX = 700_000

        attr_accessor :on_sites, :on_report, :max_thumbs

        # keys: -> { { 'tavily' => .., 'serper' => .. } }
        def initialize(http, cache, keys, logger = nil)
          super('web_models', 'Website model')
          @http = http
          @cache = cache
          @keys = keys
          @log = logger
          @run = nil
          @robots = {}      # host => rules | :pending
          @robot_wait = {}  # host => [jobs]
          @thumbs = {}      # url => data uri | false
          @on_sites = nil
          @max_thumbs = MAX_THUMBS
        end

        def online?
          true
        end

        # Đã tự lọc liên quan theo tên/đường dẫn (Việt + Anh) → bỏ qua bộ lọc chung chỉ dùng tiếng Anh.
        def prefiltered?
          true
        end

        # Chấm điểm liên quan theo đúng cụm người dùng gõ (gồm cả tiếng Việt lẫn bản dịch).
        def relevance_query(session)
          session.query.empty? ? session.oquery : session.query
        end

        def enabled?(settings)
          settings['sources']['web_models'] != false
        end

        def sites(settings)
          WebModels::SITES.select { |s| settings['sources'][s['id']] != false }
        end

        def applicable?(session, settings)
          return false unless enabled?(settings)
          return false if %w[history local favorites].include?(session.kind)
          typed = !session.query.empty? || !session.any_of.empty?
          typed && session.online_q.to_s.strip.length >= 2 && !sites(settings).empty?
        end

        def timeout
          20
        end

        def search(session, token, &done)
          return done.call('items' => [], 'next' => nil, 'error' => nil) if token
          cancel(nil) if @run
          keys = safe_keys
          run = { sid: session.sid, session: session, done: done, sites: {}, jobs: [], cancelled: false, thumbs: [], thumb_busy: 0,
                  thumb_count: 0, items: {}, keys: keys }
          @run = run
          cfg = session.settings['search'] || {}
          provs = WebModels.providers(cfg, keys)
          en = session.online_q.to_s
          sites(session.settings).each do |s|
            run[:sites][s['id']] = { 'id' => s['id'], 'name' => s['name'], 'state' => 'loading', 'count' => 0, 'error' => nil,
                                     'provider' => nil, 'search_url' => WebModels.search_url(s['id'], session.query.empty? ? en : session.query.raw),
                                     'queue' => provs.dup, 'queries' => WebModels.queries_for(s, session.query, en), 'raw' => 0 }
          end
          if provs.empty?
            run[:sites].each_value { |st| st.merge!('state' => 'error', 'error' => 'Chưa bật công cụ tìm kiếm nào (Tài khoản thư viện › Công cụ tìm kiếm).') }
            emit_sites(run)
            return done.call('items' => [], 'next' => nil, 'error' => 'Chưa bật công cụ tìm kiếm web nào.')
          end
          emit_sites(run)
          start = lambda do
            next if run[:cancelled] || @run != run
            run[:sites].each_value { |st| next_provider(run, st, keys, cfg) }
          end
          if defined?(UI) && UI.respond_to?(:start_timer) && DELAY.positive? && !ENV['MT_TEST_NO_DELAY']
            UI.start_timer(DELAY, false) { start.call }
          else
            start.call
          end
        end

        def cancel(session)
          run = @run
          return unless run && (session.nil? || run[:sid] == session.sid)
          run[:cancelled] = true
          run[:jobs].each { |j| @http.cancel(j) }
          @run = nil
        end

        def status_info(settings)
          super.merge('note' => 'Tìm model trên 3D Warehouse, 3dsky, 3DBox, Sketch Shaper, Tài liệu kiến trúc, SketchUp.vn qua công cụ ' \
                                'tìm kiếm web (Tavily không cần key; Serper/SerpApi/Brave nếu có). Không gọi API nội bộ, không đăng nhập thay ' \
                                'bạn — bấm MỞ TRANG để xem, tự đăng nhập và tải SKP; sau đó “Lưu vào thư viện”.')
        end

        private

        def safe_keys
          h = @keys ? @keys.call : {}
          h.is_a?(Hash) ? h.reject { |_, v| v.to_s.empty? } : {}
        rescue StandardError
          {}
        end

        # Thử nhà cung cấp kế tiếp cho 1 website (khi nhà cung cấp trước hết hạn mức / lỗi key).
        def next_provider(run, st, keys, cfg)
          prov = st['queue'].shift
          unless prov
            finish_site(run, st)
            return
          end
          st['provider'] = prov
          site = WebModels.site(st['id'])
          specs = st['queries'].map { |q| [q, WebModels.request_spec(prov, site, q, keys, cfg)] }.reject { |_, sp| sp.nil? }
          return next_provider(run, st, keys, cfg) if specs.empty?
          st['wait'] = specs.size
          st['quota'] = nil
          specs.each do |q, sp|
            ck = "web|#{st['id']}|#{prov}|#{q}"
            if (hit = @cache.get(ck))
              got(run, st, site, hit, keys, cfg)
              next
            end
            job = @http.request(method: sp[:method], url: sp[:url], headers: sp[:headers], body: sp[:body], timeout: timeout,
                                max_body: 2_000_000) do |res|
              next if run[:cancelled]
              begin
                raws = if res.code.to_i.zero?
                         raise HttpClient.friendly(res)
                       else
                         WebModels.parse_response(prov, res.code, res.body)
                       end
                @cache.put(ck, raws)
                got(run, st, site, raws, keys, cfg)
              rescue WebModels::QuotaError => e
                st['quota'] = "#{WebModels::PROVIDER_NAMES[prov] || prov}: #{e.message}"
                got(run, st, site, nil, keys, cfg)
              rescue StandardError => e
                st['error'] = "#{WebModels::PROVIDER_NAMES[prov] || prov}: #{e.message.to_s[0, 160]}"
                got(run, st, site, nil, keys, cfg)
              end
            end
            run[:jobs] << job
          end
        end

        def got(run, st, site, raws, keys, cfg)
          st['wait'] -= 1
          if raws
            st['raw'] += raws.size
            fresh = []
            raws.each do |r|
              it = WebModels.normalize(site, r, run[:session].query.empty? ? QueryNormalizer.analyze(run[:session].online_q) : run[:session].query)
              unless it
                (st['rejected'] ||= []) << [r['url'].to_s[0, 160], r['title'].to_s[0, 80]] if st['rejected'].to_a.size < 12
                next
              end
              k = "web:#{it['uid']}"
              next if run[:items].key?(k)
              run[:items][k] = it
              fresh << it
            end
            st['count'] += fresh.size
            unless fresh.empty?
              deliver(run, fresh)
              fresh.each { |it| queue_thumb(run, it) }
            end
          end
          return unless st['wait'] <= 0
          # Nhà cung cấp hết hạn mức/lỗi và chưa có kết quả → thử nhà cung cấp kế tiếp.
          if st['count'].zero? && (st['quota'] || st['error']) && !st['queue'].empty?
            st['error'] = nil
            return next_provider(run, st, keys, cfg)
          end
          finish_site(run, st)
        end

        # 3D Warehouse không có og:image công khai → Serper Images (nếu có key Serper): gắn ảnh cho model đã có,
        # đồng thời bổ sung các model 3D Warehouse có ảnh mà kết quả thường chưa có (vẫn qua bộ lọc link chi tiết + liên quan).
        def warehouse_images(run, st)
          key = run[:keys]['serper']
          return unless key && st['id'] == 'warehouse'
          site = WebModels.site('warehouse')
          sp = WebModels.serper_images_spec(site, st['queries'].first.to_s, key)
          run[:thumb_busy] += 1
          job = @http.request(method: sp[:method], url: sp[:url], headers: sp[:headers], body: sp[:body], timeout: 15) do |res|
            run[:thumb_busy] -= 1
            next if run[:cancelled]
            run[:wh_images] = { 'code' => res.code, 'error' => res.error.to_s[0, 120] }
            if res.ok
              q = run[:session].query.empty? ? QueryNormalizer.analyze(run[:session].online_q) : run[:session].query
              fresh = []
              matched = 0
              WebModels.parse_images(res.body).each do |r|
                it = WebModels.normalize(site, r, q)
                next unless it
                k = "web:#{it['uid']}"
                if (old = run[:items][k])
                  next if old['thumb'] || old['thumb_url']
                  old['thumb_url'] = it['thumb_url']
                  matched += 1
                  queue_thumb(run, old)
                else
                  run[:items][k] = it
                  fresh << it
                end
              end
              st['count'] += fresh.size
              run[:wh_images].merge!('matched' => matched, 'added' => fresh.size)
              unless fresh.empty?
                st['state'] = 'done'
                deliver(run, fresh)
                fresh.each { |it| queue_thumb(run, it) }
                emit_sites(run)
              end
            end
            report(run) if run[:thumb_busy].zero? && run[:thumbs].empty? && pending_sites(run).zero?
          end
          run[:jobs] << job
        rescue StandardError => e
          @log&.error('warehouse images', e)
        end

        def finish_site(run, st)
          warehouse_images(run, st) if st['provider'] == 'serper'
          st['error'] ||= st['quota'] if st['count'].zero?
          st['state'] = if st['count'].positive? then 'done'
                        elsif st['error'] then 'error'
                        else 'empty'
                        end
          emit_sites(run)
          return unless pending_sites(run).zero?
          deliver(run, [])
          report(run)
        end

        # Báo cáo lần tìm gần nhất (không chứa key) — phục vụ kiểm thử/hỗ trợ.
        def report(run)
          return unless @on_report
          s = run[:session]
          @on_report.call('time' => Time.now.strftime('%Y-%m-%d %H:%M:%S'), 'query' => s.query.empty? ? s.online_q : s.query.raw,
                          'query_en' => s.online_q,
                          'sites' => run[:sites].values.map { |x| x.reject { |k, _| %w[queue wait quota].include?(k) } },
                          'items' => run[:items].values.map do |i|
                            { 'site' => i['site'], 'title' => i['title'], 'url' => i['url'], 'thumb' => i['thumb'] ? true : false,
                              'thumb_note' => i['thumb_note'] }
                          end,
                          'thumbs_pending' => run[:thumbs].size + run[:thumb_busy], 'warehouse_images' => run[:wh_images])
        rescue StandardError => e
          @log&.error('web report', e)
        end

        def pending_sites(run)
          run[:sites].values.count { |s| s['state'] == 'loading' }
        end

        def deliver(run, items, patch = nil)
          return if run[:cancelled] || @run != run
          left = pending_sites(run)
          err = nil
          if left.zero? && run[:items].empty?
            bad = run[:sites].values.select { |s| s['state'] == 'error' }
            err = bad.first['error'] if !bad.empty? && bad.size == run[:sites].size
          end
          run[:done].call('items' => items.map { |i| i.reject { |k, _| k == 'thumb_url' } }, 'next' => nil, 'error' => err,
                          'partial' => left.positive?, 'patch' => patch)
        end

        def emit_sites(run)
          return unless @on_sites && @run == run
          @on_sites.call('sid' => run[:sid], 'sites' => run[:sites].values.map { |s| s.reject { |k, _| %w[queue queries wait quota rejected].include?(k) } })
        rescue StandardError => e
          @log&.error('web_sites emit', e)
        end

        # ------------------------------------------------------------ ảnh đại diện (nền, giới hạn song song)
        def queue_thumb(run, it)
          return if run[:thumb_count] >= @max_thumbs
          site = WebModels.site(it['site'])
          return unless it['thumb_url'] || site['og']
          run[:thumb_count] += 1
          run[:thumbs] << it
          pump(run)
        end

        def pump(run)
          while run[:thumb_busy] < THUMB_PARALLEL && (it = run[:thumbs].shift)
            run[:thumb_busy] += 1
            if (cached = @thumbs[it['url']])
              thumb_done(run, it, cached)
            elsif it['thumb_url']
              fetch_image(run, it, it['thumb_url'])
            else
              fetch_page(run, it)
            end
          end
        end

        def thumb_done(run, it, data, note = nil)
          it['thumb_note'] = note if note
          run[:thumb_busy] -= 1
          @thumbs[it['url']] = data || false
          @thumbs.shift while @thumbs.size > 400
          if data && !run[:cancelled]
            it['thumb'] = data
            deliver(run, [], { "web:#{it['uid']}" => { 'thumb' => data } })
          end
          pump(run) unless run[:cancelled]
          report(run) if run[:thumb_busy].zero? && run[:thumbs].empty? && pending_sites(run).zero? && !run[:cancelled]
        end

        def fetch_page(run, it)
          uri = URI.parse(it['url'])
          with_robots(uri.host) do |rules|
            next thumb_done(run, it, nil, 'robots') if run[:cancelled] || !WebModels.robots_allow?(rules, uri.request_uri)
            job = @http.request(url: it['url'], headers: { 'Accept' => 'text/html' }, timeout: 10, max_body: PAGE_MAX) do |res|
              img = res.ok ? WebModels.og_image(res.body) : nil
              img ? fetch_image(run, it, img) : thumb_done(run, it, nil, res.ok ? 'no og:image' : "page #{res.code} #{res.error_kind}")
            end
            run[:jobs] << job
          end
        rescue URI::InvalidURIError
          thumb_done(run, it, nil)
        end

        def fetch_image(run, it, url)
          job = @http.request(url: url, headers: { 'Accept' => 'image/jpeg,image/png,image/webp,image/gif;q=0.9,*/*;q=0.5' }, timeout: 10,
                              max_body: IMG_MAX, binary: true) do |res|
            data = res.ok ? WebModels.data_uri(res.body) : nil
            thumb_done(run, it, data, data ? nil : "img #{res.code} #{res.error_kind}")
          end
          run[:jobs] << job
        end

        def with_robots(host, &blk)
          r = @robots[host]
          return blk.call(r) if r.is_a?(Array)
          (@robot_wait[host] ||= []) << blk
          return if r == :pending
          @robots[host] = :pending
          @http.request(url: "https://#{host}/robots.txt", timeout: 10, max_body: 300_000) do |res|
            rules = res.ok ? WebModels.parse_robots(res.body) : (res.code.to_i >= 500 || res.code.to_i.zero? ? [[false, '/']] : [])
            @robots[host] = rules
            (@robot_wait.delete(host) || []).each { |b| b.call(rules) }
          end
        end
      end
    end
  end
end
