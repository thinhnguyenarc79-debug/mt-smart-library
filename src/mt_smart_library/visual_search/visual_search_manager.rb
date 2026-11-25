# frozen_string_literal: true
require 'json'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # MT VISUAL SEARCH ENGINE — tìm model theo ảnh mẫu bằng vector CLIP (không cần OpenAI).
    # Quy trình: ảnh mẫu (+ vùng cắt) → vector ảnh → (1) so với chỉ mục thumbnail thư viện máy tính,
    # (2) nhóm đồ vật dự đoán → từ khóa → lấy ứng viên online từ mọi nguồn đã bật → tải thumbnail → vector → so sánh.
    # Kết quả cuối xếp theo độ tương đồng cosine giữa ảnh mẫu và thumbnail thật của model (không phải xác suất).
    class VisualSearchManager
      SID_BASE = 900_000_000
      ONLINE_WAIT = 12.0
      MAX_ONLINE = 72
      INDEX_BATCH = 64
      MIN_KEEP = 8
      MODES = %w[exact similar wide].freeze
      MODE_LABEL = { 'exact' => 'Chính xác', 'similar' => 'Tương tự', 'wide' => 'Mở rộng' }.freeze
      # Ngưỡng mặc định theo chế độ (điểm tổng hợp hình dáng/cấu trúc/màu); chỉnh được trong model_config.json → "visual".
      THRESH = { 'exact' => { 'min' => 0.55, 'spread' => 0.20, 'keep' => 0 },
                 'similar' => { 'min' => 0.52, 'spread' => 0.25, 'keep' => 4 },
                 'wide' => { 'min' => 0.50, 'spread' => 0.30, 'keep' => MIN_KEEP } }.freeze
      # Danh mục AI (zero-shot) → danh mục tìm online của plugin (bước lấy ứng viên).
      PLUGIN_CAT = { 'sofa' => 'sofa', 'sectional sofa' => 'sofa', 'armchair' => 'chair', 'dining chair' => 'chair',
                     'office chair' => 'chair', 'bar stool' => 'chair', 'bench' => 'chair', 'ottoman' => 'chair',
                     'dining table' => 'table', 'coffee table' => 'table', 'side table' => 'table', 'desk' => 'table',
                     'dressing table' => 'table', 'bed' => 'bed', 'bunk bed' => 'bed', 'wardrobe' => 'storage',
                     'kitchen cabinet' => 'kitchen', 'tv cabinet' => 'storage', 'bookshelf' => 'storage', 'sideboard' => 'storage',
                     'chest of drawers' => 'storage', 'nightstand' => 'storage', 'pendant lamp' => 'lighting', 'chandelier' => 'lighting',
                     'floor lamp' => 'lighting', 'table lamp' => 'lighting', 'ceiling light' => 'lighting', 'wall lamp' => 'lighting',
                     'curtain' => 'curtain', 'rug' => 'decor', 'potted plant' => 'plant', 'tree' => 'plant', 'vase decor' => 'decor',
                     'wall art' => 'decor', 'mirror' => 'decor', 'bathtub' => 'bath', 'toilet' => 'bath', 'washbasin' => 'bath',
                     'kitchen appliance' => 'kitchen', 'outdoor furniture' => 'exterior' }.freeze
      IMG_HOSTS = %w[media.sketchfab.com cdn.polyhaven.com sketchup.cgtips.org img.sketchupfree.com sketchupfree.com thuviensketchup.vn].freeze

      attr_reader :store, :last_report

      # emit: ->(type, payload); online_providers: các provider online (không gồm máy tính).
      def initialize(runtime:, index:, thumbs:, online_providers:, settings:, emit:, logger: nil)
        @rt = runtime
        @index = index
        @thumbs = thumbs
        @settings = settings
        @emit = emit
        @log = logger
        @seq = 0
        @cur = nil
        @store = {}
        @filter = 'all'
        @payload = nil
        @online_providers = online_providers # mảng hoặc lambda (nguồn người dùng thêm thay đổi lúc chạy)
        @osearch = new_osearch
        @index_job = nil
        @synced_gen = nil
        @index_state = nil
        @last_image = nil
      end

      def mode
        m = @settings['visual_mode'].to_s
        MODES.include?(m) ? m : 'exact'
      end

      # Đổi chế độ Chính xác / Tương tự / Mở rộng: tìm lại với ảnh mẫu hiện tại (đặc trưng ảnh đã lưu → nhanh).
      def set_mode(m)
        return unless MODES.include?(m)
        @settings['visual_mode'] = m
        @settings.save if @settings.respond_to?(:save)
        start(@last_image[0], crop: @last_image[1]) if @last_image && File.file?(@last_image[0])
      end

      def new_osearch
        list = @online_providers.respond_to?(:call) ? @online_providers.call : @online_providers
        SearchManager.new(providers: list, settings: @settings, logger: @log,
                          emit: ->(t, pl) { @payload = pl if t == 'sr_update' && @cur && pl['sid'] == @cur[:sid] })
      end

      def active?
        !@cur.nil?
      end

      def visual_sid?(sid)
        sid.to_i >= SID_BASE
      end

      def item(key)
        @store[key.to_s]
      end

      def busy?
        !@cur.nil? || !@index_job.nil?
      end

      # ================================================================ Bắt đầu / hủy
      def start(image_path, crop: nil)
        cancel(silent: true)
        @seq += 1
        sid = SID_BASE + @seq
        vec = File.join(@rt.work_dir, 'query', "q#{@seq}.npy")
        FileUtils.mkdir_p(File.dirname(vec))
        @last_image = [image_path, crop]
        @cur = { sid: sid, image: image_path, crop: crop, vec: vec, stage: :recognizing, local: nil, online: nil, catalog: nil,
                 cats: [], allowed: {}, mode: mode, jobs: [], started: Time.now.to_f }
        @osearch = new_osearch
        @store = {}
        @payload = nil
        unless @rt.installed?
          @cur[:stage] = :need_runtime
          return state('need_runtime', @rt.status)
        end
        @rt.reset_broken # người dùng chủ động tìm: cho thử lại 1 lần sau lỗi
        sync_index
        state('recognizing', 'msg' => 'Đang nhận diện ảnh…')
        @cur[:jobs] << @rt.submit('embed_query', { 'image' => image_path, 'crop' => crop, 'out_vec' => vec }) { |r| on_embedded(sid, r) }
        sid
      end

      # Sau khi người dùng đồng ý cài bộ AI và cài xong: tiếp tục câu tìm đang chờ.
      def resume
        c = @cur
        return unless c && c[:stage] == :need_runtime
        start(c[:image], crop: c[:crop])
      end

      def cancel(silent: false)
        c = @cur
        return unless c
        c[:jobs].each { |id| @rt.cancel(id) }
        @osearch.cancel_current
        @cur = nil
        state('cancelled', 'msg' => 'Đã hủy tìm bằng ảnh.') unless silent
      end

      def set_filter(sid, f)
        return unless ResultRanker::FILTERS.include?(f)
        @filter = f
        emit_results(sid, false) if @last_sid == sid.to_i
      end

      # ================================================================ Chỉ mục thư viện máy tính
      def sync_index(force: false)
        return unless @rt.available? # bộ AI lỗi: không tự tạo việc lặp lại (chờ người dùng tìm lại hoặc sửa)
        return if @index_job
        return if !force && @synced_gen == @index.generation && @index_state && @index_state['remaining'].to_i.zero?
        gen = @index.generation
        file = File.join(@rt.work_dir, 'library.json')
        if @lib_gen != gen
          items = @index.all_entries.map do |e|
            t = @thumbs.file_for(e)
            { 'id' => e.id, 'path' => e.path, 'key' => "#{e.mtime}_#{e.size}", 'thumb' => File.file?(t) ? t : nil }
          end
          FileUtils.mkdir_p(@rt.work_dir)
          Util.atomic_write(file, JSON.generate(items))
          @lib_gen = gen
        end
        @index_job = @rt.submit('index_sync', { 'items_file' => file, 'limit' => INDEX_BATCH }, lane: 'index',
                                on_progress: ->(p) { @emit.call('vs_index', p.merge('running' => true, 'base' => (@index_state || {})['indexed'].to_i)) }) do |r|
          @index_job = nil
          if r['ok']
            @index_state = r['result']
            @synced_gen = gen
            @emit.call('vs_index', @index_state.merge('running' => r['result']['remaining'].to_i.positive?))
            sync_index if r['result']['remaining'].to_i.positive? # đợt tiếp theo (xen kẽ với câu tìm kiếm)
          else
            @log&.warn("Lập chỉ mục ảnh lỗi: #{r['error']}")
            @emit.call('vs_index', 'error' => r['error'].to_s, 'running' => false)
            @synced_gen = gen # không thử lại liên tục; lần đồng bộ sau khi thư viện đổi hoặc người dùng tìm lại
            @index_state = { 'remaining' => 0, 'indexed' => (@index_state || {})['indexed'].to_i }
          end
        end
      end

      # ================================================================ Các bước
      def on_embedded(sid, r)
        c = @cur
        return unless c && c[:sid] == sid
        return fail_with(r) unless r['ok']
        c[:cats] = Array(r['result']['categories'])
        c[:allowed] = r['result']['allowed'].is_a?(Hash) ? r['result']['allowed'] : {}
        c[:stage] = :searching
        state('searching', 'msg' => "Đang tìm model (#{MODE_LABEL[c[:mode]]})…", 'categories' => c[:cats].first(3), 'mode' => c[:mode],
                           'allowed' => allowed_vi(c))
        common = { 'vec' => c[:vec], 'mode' => c[:mode], 'allowed' => c[:allowed] }
        c[:jobs] << @rt.submit('search_local', common.merge('k' => 60, 'items_file' => File.join(@rt.work_dir, 'library.json'))) { |res| on_local(sid, res) }
        # Kho dữ liệu tích lũy: lọc danh mục + chấm lại hình dáng trên ảnh preview (không dùng điểm cũ).
        c[:jobs] << @rt.submit('catalog_search', common.merge('k' => 40, 'exclude_sources' => disabled_sources)) do |res|
          next unless @cur && @cur[:sid] == sid
          c[:catalog] = res['ok'] ? Array(res['result']['items']).map { |i| with_score(Providers::CatalogProvider.inline_thumb(i), i) } : []
          @log&.warn("Kho dữ liệu: #{res['error']}") unless res['ok']
          maybe_finish(sid)
        end
        q = online_query(c)
        if q.nil? || !@settings['sources'].values.any?
          c[:online] = []
        else
          @emit.call('sr_begin', { 'sid' => sid, 'category' => q['category'], 'category_name' => '', 'primary_en' => q['any_of'].first,
                                   'expansions' => [], 'any_of' => q['any_of'] })
          @osearch.start(q.merge('sid' => sid, 'q' => '', 'filter' => 'all'))
          c[:online_started] = Time.now.to_f
        end
      end

      # Bước lấy ứng viên online theo chế độ: Chính xác = từ khóa đúng danh mục + lọc tên theo danh mục plugin.
      def online_query(c)
        kw = keywords(c)
        return nil if kw.empty?
        top = c[:cats].first
        case c[:mode]
        when 'exact'
          { 'any_of' => kw, 'category' => PLUGIN_CAT[top['en']] || 'all', 'loose' => !PLUGIN_CAT.key?(top['en']) }
        when 'similar'
          { 'any_of' => kw, 'category' => PLUGIN_CAT[top['en']] || 'all', 'loose' => true }
        else
          { 'any_of' => kw, 'category' => 'all', 'loose' => true }
        end
      end

      def allowed_vi(c)
        vi = c[:cats].map { |x| [x['en'], x['vi']] }.to_h
        names = ->(l) { Array(l).map { |e| vi[e] || e } }
        { 'exact' => names.call(c[:allowed]['exact']), 'similar' => names.call(c[:allowed]['similar']) }
      end

      # Từ khóa lấy ứng viên online: chỉ từ các danh mục được phép của chế độ hiện tại.
      def keywords(c)
        cats = c.is_a?(Hash) ? c[:cats] : c
        return [] if cats.empty?
        mode = c.is_a?(Hash) ? c[:mode] : 'wide'
        allowed = c.is_a?(Hash) ? Array(c[:allowed][mode == 'similar' ? 'similar' : 'exact']) : []
        if mode == 'wide' || allowed.empty?
          top = cats[0]
          list = Array(top['keywords'])
          list += Array(cats[1]['keywords']).first(1) if cats[1] && top['score'].to_f - cats[1]['score'].to_f < 0.02
          return list.uniq.first(3)
        end
        kw = cats.select { |x| allowed.include?(x['en']) }.flat_map { |x| Array(x['keywords']).first(2) }
        kw = Array(cats[0]['keywords']) if kw.empty?
        kw.uniq.first(mode == 'exact' ? 3 : 5)
      end

      def with_score(item, r)
        item.reject { |k, _| %w[score parts cat cat_vi cat_p ok approx].include?(k) }.merge('vscore' => r['score'].to_f, 'vparts' => r['parts'], 'vcat' => r['cat'], 'vcat_vi' => r['cat_vi'],
                   'vcat_p' => r['cat_p'], 'vok' => r['ok'] || {}, 'vapprox' => r['approx'] ? true : false, 'title_cats' => r['title_cats'])
      end

      def on_local(sid, r)
        c = @cur
        return unless c && c[:sid] == sid
        return fail_with(r) unless r['ok']
        c[:local] = Array(r['result']['hits']).map do |h|
          e = @index[h['id']]
          next unless e
          with_score({
            'source' => 'local', 'source_label' => 'Máy tính', 'id' => e.id, 'title' => e.name, 'path' => e.path,
            'folder' => e.folder, 'size' => e.size, 'mtime' => e.mtime, 'insertable' => true, 'downloadable' => true,
            'free' => true, 'format' => 'skp', 'key' => "local:#{e.id}"
          }, h)
        end.compact
        c[:indexed] = r['result']['indexed'].to_i
        if c[:online]
          maybe_finish(sid)
        else
          emit_results(sid, true) # hiện kết quả máy tính ngay, online đến sau
        end
      end

      # Gọi từ timer: khi ứng viên online về đủ (hoặc hết giờ chờ) thì so sánh hình ảnh.
      def poll
        c = @cur
        return unless c && c[:stage] == :searching && c[:online].nil? && c[:online_started]
        pl = @payload
        waited = Time.now.to_f - c[:online_started]
        return unless (pl && !pl['loading']) || waited > ONLINE_WAIT
        # Ảnh đã được từng nguồn kiểm tra host khi đọc kết quả; ở đây chỉ nhận https.
        cands = Array(pl && pl['items']).select { |i| i['thumb'].is_a?(String) && i['thumb'].start_with?('https://') && !host(i['thumb']).empty? }
        cands = cands.first(MAX_ONLINE)
        c[:sources] = pl ? Array(pl['sources']) : []
        @osearch.cancel_current
        if cands.empty?
          c[:online] = []
          return maybe_finish(c[:sid])
        end
        c[:stage] = :comparing
        state('comparing', 'msg' => "Đang so sánh hình ảnh #{cands.size} model online…")
        by_key = cands.map { |i| [i['key'], i] }.to_h
        c[:jobs] << @rt.submit('rank_urls', { 'vec' => c[:vec], 'hosts' => cands.map { |i| host(i['thumb']) }.uniq,
                                              'mode' => c[:mode], 'allowed' => c[:allowed],
                                              'items' => cands.map { |i| { 'key' => i['key'], 'url' => i['thumb'], 'title' => i['title'] } },
                                              'store' => cands.map { |i| i.reject { |k, _| %w[score fav].include?(k) } } },
                               on_progress: ->(p) { state('comparing', 'msg' => "Đang so sánh hình ảnh… #{p['done']}/#{p['total']}") }) do |r|
          next unless @cur && @cur[:sid] == c[:sid]
          if r['ok']
            c[:online] = Array(r['result']['scores']).map { |s| by_key[s['key']] && with_score(by_key[s['key']], s) }.compact
          else
            @log&.warn("So sánh ảnh online lỗi: #{r['error']}")
            c[:online] = []
          end
          maybe_finish(c[:sid])
        end
      end

      def maybe_finish(sid)
        c = @cur
        return unless c && c[:sid] == sid && !c[:local].nil? && !c[:online].nil? && !c[:catalog].nil?
        state('done', 'msg' => 'Đang hiển thị kết quả…')
        emit_results(sid, false)
        state('done', 'msg' => done_msg(c))
        @cur = nil
      end

      def done_msg(c)
        top = c[:cats].first
        parts = []
        parts << "Nhận diện: #{top['vi']} (#{(top['prob'].to_f * 100).round}%)" if top
        parts << "chế độ #{MODE_LABEL[c[:mode]]}"
        parts << "#{@last_list.size} kết quả" if @last_list
        parts << "đã loại #{@last_rejected} model khác danh mục" if @last_rejected.to_i.positive?
        parts << "thư viện đã lập chỉ mục #{c[:indexed]} ảnh" if c[:indexed]
        parts.join(' · ')
      end

      # ================================================================ Xếp hạng & gửi lưới
      # Bước trả kết quả cuối: BỘ LỌC DANH MỤC CỨNG (chế độ Chính xác/Tương tự) + ngưỡng điểm tổng hợp thật.
      def ranked(c)
        live = Array(c[:online])
        keys = live.map { |i| i['key'] }
        list = Array(c[:local]) + live + Array(c[:catalog]).reject { |i| keys.include?(i['key']) }
        m = c[:mode] || 'exact'
        rejected = []
        unless m == 'wide'
          list, rejected = list.partition { |i| i['vok'].is_a?(Hash) && i['vok'][m] == true }
        end
        @last_rejected = rejected.size
        out = []
        unless list.empty?
          list = list.sort_by { |i| -i['vscore'] }
          best = list.first['vscore']
          t = thresholds(m)
          out = list.each_with_index.select do |i, n|
            s = i['vscore']
            s >= t['min'] && (n < t['keep'] || s >= best - t['spread'])
          end.map(&:first)
        end
        @last_report = report(c, out, list - out, rejected)
        out
      end

      def thresholds(m)
        cfg = (@rt.cfg['visual'] || {})[m]
        THRESH[m].merge(cfg.is_a?(Hash) ? cfg.select { |k, v| THRESH[m].key?(k) && v.is_a?(Numeric) } : {})
      end

      # Báo cáo kiểm tra (Hỗ trợ kỹ thuật → Mở log AI → visual_last.json): điểm thật từng ứng viên, danh mục, lý do loại.
      def report(c, kept, low, rejected)
        row = lambda do |i|
          { 'title' => i['title'], 'source' => i['source'], 'score' => i['vscore'], 'parts' => i['vparts'], 'cat' => i['vcat'],
            'cat_p' => i['vcat_p'], 'title_cats' => i['title_cats'], 'ok' => i['vok'], 'approx' => i['vapprox'] }
        end
        rep = { 'time' => Time.now.to_i, 'mode' => c[:mode], 'categories' => c[:cats], 'allowed' => c[:allowed],
                'thresholds' => thresholds(c[:mode] || 'exact'), 'kept' => kept.map(&row), 'below_threshold' => low.map(&row),
                'rejected_category' => rejected.map(&row) }
        Util.atomic_write(File.join(@rt.work_dir, 'visual_last.json'), JSON.pretty_generate(rep))
        rep
      rescue StandardError => e
        @log&.warn("Không ghi được báo cáo tìm bằng ảnh: #{e.message}")
        nil
      end

      def emit_results(sid, loading)
        c = @cur
        list = c && c[:sid] == sid ? ranked(c) : @last_list
        return unless list
        @last_list = list
        @last_sid = sid.to_i
        @store = list.map { |i| [i['key'], i] }.to_h
        counts = { 'all' => list.size }
        ResultRanker::FILTERS.drop(1).each { |f| counts[f] = ResultRanker.apply_filter(list, f).size }
        favs = @settings['favorites']
        ofav = Array(@settings['online_favorites']).map { |f| f['key'] }
        items = ResultRanker.apply_filter(list, @filter).map do |i|
          i.merge('fav' => i['source'] == 'local' ? favs.include?(i['id']) : ofav.include?(i['key']),
                  'vscore' => i['vscore'].round(3), 'score' => i['vscore'])
           .reject { |k, _| %w[tags cats hist_rank rel vok title_cats].include?(k) }
        end
        @emit.call('sr_update', { 'sid' => sid, 'items' => items, 'counts' => counts, 'filter' => @filter, 'loading' => loading,
                                  'has_more' => false, 'sources' => c ? Array(c[:sources]) : [], 'hidden' => 0, 'truncated' => false,
                                  'visual' => true, 'vmode' => c ? c[:mode] : mode, 'rejected' => @last_rejected.to_i })
      end

      def disabled_sources
        @settings['sources'].select { |_, v| v == false }.keys
      end

      private

      def state(s, extra = {})
        @emit.call('vs_state', extra.merge('state' => s, 'sid' => @cur && @cur[:sid]))
      end

      def fail_with(r)
        c = @cur
        @cur = nil
        if r['cancelled']
          state('cancelled', 'msg' => 'Đã hủy tìm bằng ảnh.')
        else
          @emit.call('vs_state', 'state' => 'error', 'msg' => "Tìm bằng ảnh lỗi: #{r['error']}", 'sid' => c && c[:sid])
        end
      end

      def host(url)
        URI.parse(url).host.to_s.downcase
      rescue URI::InvalidURIError
        ''
      end
    end
  end
end
