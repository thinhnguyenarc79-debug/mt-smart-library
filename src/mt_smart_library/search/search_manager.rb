# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Bộ máy tìm kiếm tổng hợp: gửi truy vấn tới mọi nguồn song song, nhận kết quả theo đợt,
    # lọc liên quan, loại trùng, xếp hạng và gửi cả lưới về giao diện ngay khi có đợt mới.
    # Chạy ở main thread; nguồn online dùng HttpClient (luồng nền) nên không chặn SketchUp.
    class SearchManager
      Session = Struct.new(:sid, :query, :any_of, :online_q, :cat, :cat_terms, :kind, :filter, :store, :states,
                           :settings, :hidden, :started, :oquery, :loose)
      MAX_SEND = 900

      attr_reader :providers, :session

      # emit: ->(type, payload)
      def initialize(providers:, settings:, emit:, logger: nil)
        @providers = providers
        @settings = settings
        @emit = emit
        @log = logger
        @session = nil
      end

      def start(params)
        cancel_current
        st = @settings
        cat = Categories.find(params['category'] || 'all', st['categories_custom'])
        any_of = Array(params['any_of']).map { |x| Util.utf8(x).strip[0, 100] }.reject(&:empty?).first(12)
        q = QueryNormalizer.analyze(params['q'].to_s)
        online_text = if !any_of.empty?
                        any_of.find { |x| x.ascii_only? } || QueryNormalizer.analyze(any_of.first).primary_en
                      elsif !q.empty?
                        q.primary_en
                      else
                        Categories.online_query(cat)
                      end
        oq = online_text ? QueryNormalizer.analyze(online_text) : nil
        kind = cat['kind'] || 'category'
        filter = ResultRanker::FILTERS.include?(params['filter']) ? params['filter'] : 'all'
        s = Session.new(params['sid'].to_i, q, any_of, online_text, cat, Categories.terms(cat), kind, filter, {}, {}, st, 0,
                        Time.now.to_f, oq || q, params['loose'] == true)
        @session = s
        @providers.each do |p|
          next unless p.applicable?(s, st)
          s.states[p.id] = { 'id' => p.id, 'label' => p.label, 'state' => 'loading', 'next' => nil, 'count' => 0, 'error' => nil,
                             'online' => p.online? }
        end
        add_online_favorites(s) if kind == 'favorites'
        emit_begin(s)
        @providers.each { |p| fetch(p, nil) if s.states[p.id] }
        emit_update
        s.sid
      end

      # Tải đợt tiếp theo của các nguồn còn dữ liệu (cuộn tới cuối lưới).
      def more(sid)
        s = @session
        return unless s && s.sid == sid.to_i
        @providers.each do |p|
          stt = s.states[p.id]
          next unless stt && stt['state'] == 'done' && !stt['next'].nil?
          stt['state'] = 'loading'
          fetch(p, stt['next'])
        end
        emit_update
      end

      def set_filter(sid, filter)
        s = @session
        return unless s && s.sid == sid.to_i && ResultRanker::FILTERS.include?(filter)
        s.filter = filter
        emit_update
      end

      def cancel_current
        return unless @session
        @providers.each { |p| p.cancel(@session) }
        @session = nil
      end

      def item(key)
        @session && @session.store[key.to_s]
      end

      def refresh
        emit_update if @session
      end

      private

      def fetch(provider, token)
        s = @session
        sid = s.sid
        provider.search(s, token) do |res|
          cur = @session
          next unless cur && cur.sid == sid # kết quả của truy vấn cũ: bỏ qua
          handle(provider, res)
        end
      rescue StandardError => e
        @log&.error("Nguồn #{provider.id} lỗi", e)
        st = s.states[provider.id]
        st.merge!('state' => 'error', 'error' => e.message, 'next' => nil) if st
      end

      def handle(provider, res)
        s = @session
        st = s.states[provider.id]
        items = Array(res['items'])
        oq = provider.relevance_query(s)
        apply_patch(s, res['patch']) if res['patch'].is_a?(Hash)
        if provider.online? && !s.loose && !(provider.respond_to?(:prefiltered?) && provider.prefiltered?) # tìm bằng ảnh: lọc bằng độ tương đồng hình ảnh thay cho lọc tên
          before = items.size
          items = items.select { |it| ResultRanker.relevant_online?(it, oq, s.cat_terms) }
          s.hidden += before - items.size
        end
        items.each { |it| it['score'] = ResultRanker.score(it, provider.online? ? oq : s.query, s.cat_terms) }
        added = ResultRanker.merge_into(s.store, items)
        st['count'] += added
        st['next'] = res['next']
        st['error'] = res['error']
        st['offline'] = res['offline'] ? true : false
        st['state'] = if res['partial'] then 'loading'
                      elsif res['error'] then 'error'
                      else 'done'
                      end
        st['total'] = res['total'] if res['total']
        emit_update
      rescue StandardError => e
        @log&.error("Xử lý kết quả #{provider.id} lỗi", e)
        st.merge!('state' => 'error', 'error' => e.message) if st
        emit_update
      end

      # Cập nhật trường của item đã có trên lưới (ví dụ ảnh đại diện website tải xong sau).
      def apply_patch(s, patch)
        patch.each do |key, fields|
          it = s.store[key.to_s]
          next unless it && fields.is_a?(Hash)
          fields.each { |k, v| it[k.to_s] = v if %w[thumb thumb_large].include?(k.to_s) }
        end
      end

      def add_online_favorites(s)
        favs = Array(@settings['online_favorites'])
        unless s.query.empty?
          groups = s.query.groups
          favs = favs.select do |f|
            hay = ' ' + Util.fold(f['title']) + ' '
            groups.all? { |alts| alts.any? { |a| hay.include?(a) } }
          end
        end
        items = favs.map { |f| f.merge('insertable' => false, 'score' => 50) }
        ResultRanker.merge_into(s.store, items)
      end

      def emit_begin(s)
        @emit.call('sr_begin', {
                     'sid' => s.sid, 'category' => s.cat['id'], 'category_name' => s.cat['name'],
                     'primary_en' => s.online_q, 'expansions' => s.query.empty? ? [] : s.query.expansions,
                     'any_of' => s.any_of
                   })
      end

      def emit_update
        s = @session
        return unless s
        list = s.store.values
        list = if s.kind == 'history'
                 list.sort_by { |i| i['hist_rank'] || 1_000_000 }
               elsif s.query.empty? && s.any_of.empty? && !list.any? { |i| i['source'] != 'local' }
                 list.sort_by { |i| i['title'].to_s.downcase }
               else
                 ResultRanker.rank(list)
               end
        counts = { 'all' => list.size }
        ResultRanker::FILTERS.drop(1).each { |f| counts[f] = ResultRanker.apply_filter(list, f).size }
        # Máy tính: hiển thị tổng số model khớp (kể cả phần chưa tải lên lưới).
        lst = s.states['local']
        if lst && lst['total'].to_i > counts['local']
          extra = lst['total'].to_i - counts['local']
          %w[all local insertable free].each { |f| counts[f] += extra }
        end
        shown = ResultRanker.apply_filter(list, s.filter)
        favs = @settings['favorites']
        ofav = Array(@settings['online_favorites']).map { |f| f['key'] }
        items = shown.first(MAX_SEND).map do |i|
          i.merge('fav' => i['source'] == 'local' ? favs.include?(i['id']) : ofav.include?(i['key']))
           .reject { |k, _| %w[tags cats hist_rank rel].include?(k) }
        end
        loading = s.states.values.any? { |v| v['state'] == 'loading' }
        @emit.call('sr_update', {
                     'sid' => s.sid, 'items' => items, 'counts' => counts, 'filter' => s.filter, 'loading' => loading,
                     'has_more' => s.states.values.any? { |v| v['state'] == 'done' && !v['next'].nil? },
                     'sources' => s.states.values.map { |v| v.reject { |k, _| k == 'next' } },
                     'hidden' => s.hidden, 'truncated' => shown.size > MAX_SEND
                   })
      end
    end
  end
end
