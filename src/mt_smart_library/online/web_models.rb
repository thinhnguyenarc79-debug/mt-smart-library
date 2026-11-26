# frozen_string_literal: true
require 'uri'
require 'json'
require 'digest'
require 'base64'

module MTDesign
  module SmartLibrary
    # Tìm model trên các website thư viện 3D QUA CÔNG CỤ TÌM KIẾM WEB (Tavily / Serper / SerpApi / Brave / SearXNG)
    # — không gọi API nội bộ của website, không đăng nhập thay người dùng, không vượt cơ chế bảo vệ.
    # Module thuần hàm: tạo truy vấn, nhận diện link chi tiết model, chuẩn hóa tên, lọc liên quan, đọc og:image, robots.txt.
    module WebModels
      SITES = [
        { 'id' => 'warehouse', 'name' => '3D Warehouse', 'host' => '3dwarehouse.sketchup.com', 'path' => '/model/',
          'hosts' => %w[3dwarehouse.sketchup.com embed-3dwarehouse-classic.sketchup.com],
          'detail' => %r{\A/model/([0-9a-z][0-9a-z\-]{7,})(?:/([^/?#]*))?/?\z}i, 'lang' => 'en', 'og' => false,
          'search_url' => 'https://3dwarehouse.sketchup.com/search/models?q=%s' },
        { 'id' => '3dsky', 'name' => '3dsky', 'host' => '3dsky.org', 'path' => '/3dmodels/show/',
          'hosts' => %w[3dsky.org www.3dsky.org],
          'detail' => %r{\A/3dmodels/show/([a-z0-9_\-]{3,})/?\z}i, 'lang' => 'en', 'og' => true,
          'search_url' => 'https://3dsky.org/3dmodels?query=%s' },
        { 'id' => '3dbox', 'name' => '3DBox', 'host' => '3dbox.cc', 'path' => '/detail/',
          'hosts' => %w[3dbox.cc www.3dbox.cc],
          'detail' => %r{\A/detail/(\d{6,})/?\z}, 'lang' => 'en', 'og' => true,
          'search_url' => nil },
        { 'id' => 'sketchshaper', 'name' => 'Sketch Shaper', 'host' => 'www.sketchshaper.com', 'path' => '/sketchup-3d-models/',
          'hosts' => %w[www.sketchshaper.com sketchshaper.com],
          'detail' => %r{\A/sketchup-3d-models(?:-\d+)?/[a-z0-9\-]+/([a-z0-9\-]+-\d+)/?\z}i, 'lang' => 'en', 'og' => true,
          'search_url' => 'https://www.sketchshaper.com/sketchup-3d-models-3?search=%s' },
        { 'id' => 'tailieukientruc', 'name' => 'Tài liệu kiến trúc', 'host' => 'tailieukientruc.net', 'path' => '/',
          'hosts' => %w[tailieukientruc.net www.tailieukientruc.net],
          'detail' => %r{\A/([a-z0-9\-]+-(\d{4,}))\.html\z}i, 'lang' => 'vi', 'og' => true, 'need_skp_word' => true,
          'google_extra' => 'sketchup -inurl:tim-kiem -inurl:search',
          'search_url' => nil },
        { 'id' => 'sketchupvn', 'name' => 'SketchUp.vn', 'host' => 'sketchup.vn', 'path' => '/',
          'hosts' => %w[sketchup.vn www.sketchup.vn],
          'detail' => %r{\A/(?:bai-viet|single-video|single-photo)/(tID\d+)_[^/]+\.html\z}i, 'lang' => 'vi', 'og' => true, 'need_skp_word' => true,
          'google_extra' => 'model',
          'search_url' => nil }
      ].freeze
      BY_ID = SITES.map { |s| [s['id'], s] }.to_h.freeze
      # Mọi host website nguồn (cho phép mở link chi tiết trên trình duyệt).
      HOSTS = SITES.flat_map { |s| s['hosts'] }.uniq.freeze
      SKP_WORDS = /sketchup|\bskp\b|\bsu\b|model|mô hình|mo hinh|3d/i.freeze
      TUTORIAL = /\A\s*(hướng dẫn|huong dan|cách |cach |video|tutorial|cuộc thi|cuoc thi)/i.freeze
      PROVIDERS = %w[serper serpapi brave searxng tavily].freeze
      PROVIDER_NAMES = { 'tavily' => 'Tavily', 'serper' => 'Serper', 'serpapi' => 'SerpApi', 'brave' => 'Brave', 'searxng' => 'SearXNG' }.freeze

      module_function

      def site(id)
        BY_ID[id.to_s]
      end

      # Link tìm trực tiếp trên website nguồn; website không có tham số tìm kiếm công khai → tìm Google giới hạn trong website đó.
      def search_url(site_id, q)
        s = site(site_id)
        return nil unless s
        text = Util.utf8(q).strip[0, 120]
        if s['search_url']
          format(s['search_url'], URI.encode_www_form_component(text))
        else
          'https://www.google.com/search?q=' + URI.encode_www_form_component("site:#{s['host']}#{s['path'] == '/' ? '' : s['path'].chomp('/')} #{text}")
        end
      end

      # Các từ khóa sẽ tìm cho một website: website tiếng Anh dùng bản dịch tiếng Anh;
      # website Việt dùng cả cụm tiếng Việt người dùng gõ và bản tiếng Anh.
      # 1 truy vấn / website / lần tìm (tiết kiệm hạn mức: Tavily không key chỉ cho số lượt giới hạn mỗi giờ).
      def queries_for(site_def, query, en)
        en = Util.utf8(en).strip
        vi = query && !query.empty? ? Util.utf8(query.raw).strip : ''
        q = if site_def['lang'] == 'vi' && !vi.empty? && Util.fold(vi) != Util.fold(en) then vi
            elsif !en.empty? then en
            else vi
            end
        q.empty? ? [] : [q]
      end

      # Đặc tả 1 request tới nhà cung cấp tìm kiếm (không chứa key trong URL ngoài SerpApi — log luôn ẩn query string).
      # → { method:, url:, headers:, body: } hoặc nil nếu nhà cung cấp chưa sẵn sàng.
      def request_spec(provider, site_def, q, keys, cfg, count: 10)
        scope = site_def['host'] + (site_def['path'] == '/' ? '' : site_def['path'].chomp('/'))
        site_q = "site:#{scope} #{q} #{site_def['google_extra']}".strip
        case provider
        when 'tavily'
          key = keys['tavily']
          hdr = key ? { 'Authorization' => "Bearer #{key}" } : { 'X-Tavily-Access-Mode' => 'keyless' }
          body = { 'query' => "#{q} #{site_def['lang'] == 'vi' ? 'sketchup' : '3d model'}", 'max_results' => [count, 20].min,
                   'include_domains' => [site_def['host'].sub(/\Awww\./, '')] }
          { method: 'POST', url: base('tavily', 'https://api.tavily.com') + '/search', headers: hdr.merge('Content-Type' => 'application/json'),
            body: JSON.generate(body) }
        when 'serper'
          return nil unless keys['serper']
          # Không đặt gl=vn: Serper khi đó trả link chuyển hướng google.com/goto (không dùng được).
          body = { 'q' => site_q, 'num' => [count, 20].min }
          { method: 'POST', url: base('serper', 'https://google.serper.dev') + '/search',
            headers: { 'X-API-KEY' => keys['serper'], 'Content-Type' => 'application/json' }, body: JSON.generate(body) }
        when 'serpapi'
          return nil unless keys['serpapi']
          { method: 'GET', url: base('serpapi', 'https://serpapi.com') + '/search.json?' +
            URI.encode_www_form('engine' => 'google', 'q' => site_q, 'num' => [count, 20].min, 'api_key' => keys['serpapi']), headers: {} }
        when 'brave'
          return nil unless keys['brave']
          { method: 'GET', url: base('brave', 'https://api.search.brave.com/res/v1/web/search') + '?' +
            URI.encode_www_form('q' => site_q, 'count' => [count, 20].min), headers: { 'X-Subscription-Token' => keys['brave'] } }
        when 'searxng'
          b = cfg['searxng_url'].to_s.sub(%r{/+\z}, '')
          return nil if b.empty?
          { method: 'GET', url: b + '/search?' + URI.encode_www_form('q' => site_q, 'format' => 'json'), headers: {} }
        end
      end

      def base(name, default)
        v = ENV["MT_TEST_#{name.upcase}_BASE"].to_s
        v.empty? ? default : v.sub(%r{/+\z}, '')
      end

      # Danh sách nhà cung cấp dùng được theo thứ tự cài đặt (Google trước nếu có key vì hỗ trợ toán tử site:).
      def providers(cfg, keys)
        order = Array(cfg['order']).select { |p| PROVIDERS.include?(p) }
        order += PROVIDERS - order
        en = cfg['enabled'] || {}
        list = order.select do |p|
          next false if en[p] == false
          case p
          when 'tavily' then true
          when 'searxng' then !cfg['searxng_url'].to_s.empty?
          else !keys[p].to_s.empty?
          end
        end
        # Nhà cung cấp có toán tử site: (Google/Brave) cho kết quả đúng website tốt hơn → ưu tiên khi có key.
        list.sort_by { |p| [p == 'tavily' ? 1 : 0, order.index(p)] }
      end

      class QuotaError < StandardError; end

      # Đọc phản hồi của nhà cung cấp → [{url, title, snippet, thumb}]
      def parse_response(provider, code, body)
        if body.to_s.include?('hourly_cap_reached')
          raise QuotaError, 'Tavily không cần key đã hết lượt trong giờ này — thêm key Tavily (miễn phí 1.000 lượt/tháng) hoặc Serper'
        end
        if [401, 402, 403, 429, 432, 433].include?(code.to_i)
          raise QuotaError, "HTTP #{code} (key sai, hết hạn mức hoặc bị giới hạn tốc độ)"
        end
        raise "HTTP #{code}" unless code.to_i == 200
        d = JSON.parse(body.to_s)
        case provider
        when 'tavily'
          Array(d['results']).map { |r| { 'url' => r['url'], 'title' => r['title'], 'snippet' => r['content'].to_s, 'thumb' => nil } }
        when 'serper'
          Array(d['organic']).map { |r| { 'url' => r['link'], 'title' => r['title'], 'snippet' => r['snippet'].to_s, 'thumb' => r['imageUrl'] } }
        when 'serpapi'
          if d['error'] && !d['organic_results']
            return [] if d['error'].to_s =~ /hasn.t returned any results/i
            raise QuotaError, d['error'].to_s[0, 120]
          end
          Array(d['organic_results']).map { |r| { 'url' => r['link'], 'title' => r['title'], 'snippet' => r['snippet'].to_s, 'thumb' => r['thumbnail'] } }
        when 'brave'
          Array((d['web'] || {})['results']).map do |r|
            th = (r['thumbnail'] || {})
            { 'url' => r['url'], 'title' => strip_tags(r['title']), 'snippet' => strip_tags(r['description']), 'thumb' => th['src'] || th['original'] }
          end
        when 'searxng'
          Array(d['results']).map { |r| { 'url' => r['url'], 'title' => r['title'], 'snippet' => r['content'].to_s, 'thumb' => r['thumbnail'] || r['img_src'] } }
        else []
        end
      end

      # Serper Images: ảnh đại diện cho website không có og:image công khai (3D Warehouse). → { link_trang => url_ảnh }
      def serper_images_spec(site_def, q, key)
        { method: 'POST', url: base('serper', 'https://google.serper.dev') + '/images',
          headers: { 'X-API-KEY' => key, 'Content-Type' => 'application/json' },
          body: JSON.generate('q' => "site:#{site_def['host']} #{q}") }
      end

      # → [{url, title, snippet, thumb}] (cùng dạng kết quả tìm kiếm thường)
      def parse_images(body)
        Array(JSON.parse(body.to_s)['images']).map do |r|
          { 'url' => r['link'].to_s, 'title' => r['title'].to_s, 'snippet' => '', 'thumb' => r['imageUrl'] || r['thumbnailUrl'] }
        end.select { |r| !r['url'].empty? && r['thumb'].to_s.start_with?('https://') }
      rescue JSON::ParserError
        []
      end

      def strip_tags(s)
        Util.utf8(s.to_s).gsub(/<[^>]+>/, '').gsub('&amp;', '&').gsub('&quot;', '"').gsub('&#39;', "'").strip
      end

      # Link CHI TIẾT model thật của website (không phải trang chủ, trang tìm kiếm, danh mục, tag).
      # → [canonical_url, id_trong_site] hoặc nil
      def detail_link(site_def, url)
        u = URI.parse(url.to_s.strip)
        return nil unless u.is_a?(URI::HTTP) && u.host
        return nil unless site_def['hosts'].include?(u.host.downcase)
        path = URI.decode_www_form_component(u.path.to_s.gsub('+', '%2B')) rescue u.path.to_s # rubocop:disable Style/RescueModifier
        m = site_def['detail'].match(path)
        return nil unless m
        id = site_def['id'] == 'tailieukientruc' ? m[2] : m[1] # Tài liệu kiến trúc: cùng mã bài, slug khác nhau
        canon = case site_def['id']
                when 'warehouse' then "https://3dwarehouse.sketchup.com/model/#{m[1]}#{m[2] && !m[2].empty? ? "/#{u.path.split('/')[3]}" : ''}"
                when '3dsky' then "https://3dsky.org/3dmodels/show/#{m[1]}"
                when '3dbox' then "https://3dbox.cc/detail/#{m[1]}"
                when 'sketchshaper' then "https://www.sketchshaper.com#{u.path.chomp('/')}"
                else "https://#{site_def['host']}#{u.path}"
                end
        [canon, "#{site_def['id']}:#{id.downcase}"]
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      SUFFIX = [/\s*[|\-–]\s*3D Warehouse\s*-\s*SketchUp\s*\z/i, /\s*[|\-–]\s*3dsky\.org\s*\z/i, /\s*[|\-–]\s*3D Warehouse\s*\z/i, /\s*[|\-–]\s*3Dbox\s*\z/i, /\s*[|\-–]\s*3dsky\s*\z/i, /\s*-\s*Model\s*\z/,
                /\s*[|\-–]\s*(Thư viện kiến trúc|Tài Liệu Kiến Trúc|Sketchup \.vn|Cộng đồng Sketchup Việt Nam)\s*\z/i, /\s*\|\s*SKP Download\s*\z/i, /\s*\|\s*3D Model\s*\z/i, /\s*\|\s*Sketch\s*shaper\s*\z/i,
                /\s*\|\s*SKP File\s*\z/i, /\s*-\s*[^-|]{1,40}\s*-\s*3D model\s*\z/i, /\s*-\s*3D model\s*\z/i,
                /\s*[|\-–]\s*(SketchUp\.vn|sketchup\.vn|SUVN|Tài liệu kiến trúc|TLKT(?:NET)?)\s*\z/i].freeze

      # Tên model sạch: bỏ đuôi tên website, số thứ tự đầu dòng.
      def clean_title(site_def, title, url)
        t = strip_tags(title)
        6.times do
          before = t
          SUFFIX.each { |rx| t = t.sub(rx, '') }
          t = t.sub(/\s*\|\s*[^|]{1,30}\z/, '') if site_def['id'] == '3dbox' && t.count('|') >= 1 && t =~ /\|\s*[^|]*\z/
          t = t.sub(/\s*-\s*[A-Za-z ]{1,30}\z/, '') if site_def['id'] == '3dbox' && t =~ /…\s*-\s*[A-Za-z ]{1,30}\z/
          if %w[sketchshaper warehouse].include?(site_def['id'])
            t = t.sub(/\s*[-|–]\s*Sketch\s*shaper.*\z/i, '').sub(/\s*(?:[-|–]\s*)?(?:free\s+)?SketchUp 3D Models?\b.*\z/i, '')
                 .sub(/\s*3d\s+SketchUp\s+model.*\z/i, '').sub(/\s+3D Model\s*\z/i, '')
          end
          break if t == before
        end
        t = t.sub(/\A\s*\d{1,4}\s*[.)]\s+/, '')
        t = t.sub(/\s*\.{3}\s*\z/, '…')
        if t.strip.empty? || t =~ /\A(3D Warehouse|3dsky|3Dbox|Sketch shaper)\z/i
          slug = URI.parse(url).path.split('/').last.to_s.sub(/\.html\z/, '').sub(/-\d+\z/, '').tr('-_', '  ')
          t = URI.decode_www_form_component(slug) rescue slug # rubocop:disable Style/RescueModifier
        end
        t.strip[0, 140]
      end

      # Kiểm tra liên quan: mọi nhóm "đồ vật chính" của truy vấn phải xuất hiện trong tên hoặc đường dẫn (Việt/Anh).
      # Cụm nhiều từ khớp khi mọi từ đều có mặt (không cần liền nhau): "vách cnc" ↔ "Vách ngăn CNC".
      def relevant?(query, item_text)
        groups = QueryNormalizer.online_groups(query)
        return true if groups.empty?
        hay = ' ' + Util.fold(item_text).gsub(/[^a-z0-9]+/, ' ') + ' '
        must = groups.select { |g| g['object'] }
        must = groups if must.empty?
        must.all? { |g| g['alts'].any? { |a| alt_hit?(hay, a) } }
      end

      def alt_hit?(hay, alt)
        words = alt.gsub(/[^a-z0-9]+/, ' ').split(' ')
        return false if words.empty?
        words.all? { |w| w.length <= 3 ? hay.include?(" #{w} ") || hay.include?(" #{w}s ") : hay.include?(" #{w}") }
      end

      # Kết quả thô của nhà cung cấp → item chuẩn của thư viện (hoặc nil nếu không phải link chi tiết / không liên quan).
      def normalize(site_def, raw, query)
        dl = detail_link(site_def, raw['url'])
        return nil unless dl
        canon, sid = dl
        title = clean_title(site_def, raw['title'], canon)
        slug = URI.parse(canon).path.tr('/_-', '   ')
        slug = (URI.decode_www_form_component(slug) rescue slug) # rubocop:disable Style/RescueModifier
        text = "#{title} #{slug}"
        return nil if site_def['need_skp_word'] && "#{text} #{raw['snippet']}" !~ SKP_WORDS
        return nil if TUTORIAL.match?(title)
        return nil unless relevant?(query, text)
        uid = Digest::SHA1.hexdigest(sid)[0, 20]
        th = raw['thumb'].to_s =~ %r{\Ahttps://}i ? raw['thumb'] : nil
        { 'source' => 'web', 'source_label' => site_def['name'], 'site' => site_def['id'], 'uid' => uid, 'title' => title,
          'url' => canon, 'snippet' => strip_tags(raw['snippet'])[0, 300], 'thumb_url' => th, 'thumb' => nil,
          'insertable' => false, 'downloadable' => false, 'free' => false, 'web_model' => true, 'author' => nil,
          'license' => 'Theo điều khoản của website nguồn', 'format' => nil, 'tags' => [] }
      end

      # og:image (chỉ https) trong HTML trang chi tiết.
      def og_image(html)
        h = html.to_s[0, 400_000]
        m = h.match(/<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]*content=["']([^"']+)["']/i) ||
            h.match(/<meta[^>]+content=["']([^"']+)["'][^>]*property=["']og:image["']/i) ||
            h.match(/<meta[^>]+name=["']twitter:image["'][^>]*content=["']([^"']+)["']/i)
        return nil unless m
        u = m[1].gsub('&amp;', '&').strip
        u =~ %r{\Ahttps://[^\s"'<>]+\z}i ? u : nil
      end

      # Ảnh → data URI (giao diện chỉ hiển thị ảnh data: hoặc host đã duyệt).
      def data_uri(bytes)
        b = bytes.to_s.b
        mime = if b.start_with?("\xFF\xD8\xFF".b) then 'image/jpeg'
               elsif b.start_with?("\x89PNG".b) then 'image/png'
               elsif b[0, 4] == 'RIFF' && b[8, 4] == 'WEBP' then 'image/webp'
               elsif b.start_with?('GIF8') then 'image/gif'
               end
        return nil unless mime && b.bytesize > 200
        "data:#{mime};base64,#{Base64.strict_encode64(b)}"
      end

      # ---------------------------------------------------------------- robots.txt (tôn trọng khi đọc trang chi tiết lấy ảnh)
      UA_TOKEN = 'mt-smart-library-pro'

      def parse_robots(text)
        groups = []
        cur = nil
        text.to_s.each_line do |line|
          l = line.sub(/#.*/, '').strip
          next if l.empty?
          k, v = l.split(':', 2).map { |x| x.to_s.strip }
          case k.downcase
          when 'user-agent'
            cur = { agents: [], rules: [] } if cur.nil? || !cur[:rules].empty?
            groups << cur unless groups.include?(cur)
            cur[:agents] << v.downcase
          when 'allow', 'disallow'
            cur[:rules] << [k.downcase == 'allow', v] if cur
          end
        end
        mine = groups.select { |g| g[:agents].any? { |a| a != '*' && UA_TOKEN.include?(a) } }
        mine = groups.select { |g| g[:agents].include?('*') } if mine.empty?
        mine.flat_map { |g| g[:rules] }
      end

      # Quy tắc dài nhất khớp thắng (chuẩn RFC 9309); Disallow rỗng = cho phép.
      def robots_allow?(rules, path)
        best = nil
        rules.each do |allow, pat|
          next if pat.empty?
          rx = Regexp.new('\A' + Regexp.escape(pat).gsub('\*', '.*').sub(/\\\$\z/, '\z'))
          next unless rx.match?(path)
          best = [allow, pat.length] if best.nil? || pat.length > best[1] || (pat.length == best[1] && allow)
        end
        best.nil? || best[0]
      end
    end
  end
end
