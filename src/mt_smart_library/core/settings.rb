# frozen_string_literal: true
require 'json'

module MTDesign
  module SmartLibrary
    # settings.json có schema; KHÔNG BAO GIỜ chứa API key/token (chỉ lưu theo whitelist).
    class Settings
      SCHEMA = 2
      DEFAULT_MODEL = 'gpt-6-luna'
      LEGACY_DEFAULT_MODELS = %w[gpt-4.1-mini].freeze
      SORTS = %w[relevance name name_desc small large new old].freeze
      DEFAULTS = {
        'schema' => SCHEMA,
        'roots' => [],
        'favorites' => [],
        'history' => [],
        'quick_scan' => true,
        'scan_on_open' => true,
        'ui' => { 'page_size' => 48, 'sort' => 'relevance', 'size_max_mb' => 0, 'tab' => 'offline',
                  'thumb_size' => 200, 'filter' => 'all', 'category' => 'all' },
        'categories_custom' => [],
        'online_favorites' => [],
        'sources' => { 'sketchfab' => true, 'polyhaven' => true, 'cgtips' => true, 'sketchupfree' => true, 'thuviensketchup' => true },
        'auto_save_downloads' => true,
        'converter' => { 'blender_path' => '', 'blender_version' => '', 'blender_ok' => false, 'blender_reason' => '',
                         'timeout' => 600, 'gltf_engine' => 'auto' },
        'ai' => { 'model' => DEFAULT_MODEL, 'base_url' => 'https://api.openai.com/v1', 'detail' => 'low', 'remember_key' => false },
        'sketchfab' => { 'downloadable_only' => true, 'token_type' => 'token', 'remember_token' => false },
        'net' => { 'timeout' => 30 },
        'update' => { 'source' => 'none', 'manifest_url' => '', 'github_repo' => '', 'check_on_start' => false }
      }.freeze
      HISTORY_MAX = 300
      FAVORITES_MAX = 20_000

      attr_reader :path, :data, :load_warning

      def initialize(path, logger = nil)
        @path = path
        @logger = logger
        @data = deep_dup(DEFAULTS)
        @load_warning = nil
        load
      end

      def [](key)
        @data[key]
      end

      def load
        raw = begin
          Util.read_json(@path)
        rescue StandardError => e
          quarantine(e)
          begin
            Util.read_json(@path)
          rescue StandardError
            nil
          end
        end
        @data = sanitize(raw.is_a?(Hash) ? migrate(raw) : {})
      end

      def save
        Util.atomic_write(@path, JSON.pretty_generate(@data))
      rescue StandardError => e
        @logger&.error('Không ghi được settings.json', e)
        false
      end

      def roots
        @data['roots']
      end

      def add_root(path)
        p = Util.norm_path(path)
        return false if p.empty?
        return false if roots.any? { |r| Util.path_key(r) == Util.path_key(p) }
        roots << p
        true
      end

      def remove_root(path)
        k = Util.path_key(path)
        before = roots.size
        roots.reject! { |r| Util.path_key(r) == k }
        before != roots.size
      end

      def toggle_favorite(id)
        f = @data['favorites']
        if f.include?(id)
          f.delete(id)
          false
        else
          f.unshift(id)
          f.pop while f.size > FAVORITES_MAX
          true
        end
      end

      def push_history(id)
        h = @data['history']
        h.delete(id)
        h.unshift(id)
        h.pop while h.size > HISTORY_MAX
      end

      # Cập nhật từ UI: chỉ nhận khóa hợp lệ.
      def apply_ui(patch)
        return unless patch.is_a?(Hash)
        merged = deep_dup(@data)
        %w[quick_scan scan_on_open auto_save_downloads].each { |k| merged[k] = patch[k] if patch.key?(k) }
        %w[ui ai sketchfab net update sources].each do |sec|
          next unless patch[sec].is_a?(Hash)
          patch[sec].each { |k, v| merged[sec][k] = v if DEFAULTS[sec].key?(k) }
        end
        if patch['converter'].is_a?(Hash) # giao diện chỉ được đổi thời gian chờ và cách đọc glTF
          %w[timeout gltf_engine].each { |k| merged['converter'][k] = patch['converter'][k] if patch['converter'].key?(k) }
        end
        @data = sanitize(merged)
      end

      ONLINE_FAV_KEYS = %w[key source source_label uid title thumb thumb_large author author_url license url downloadable free
                           format formats faces likes].freeze
      ONLINE_FAV_MAX = 500

      # Yêu thích kết quả online: lưu ảnh chụp thông tin (không có bí mật) để xem lại khi offline.
      def toggle_online_favorite(item)
        list = @data['online_favorites']
        key = item['key'].to_s
        if list.any? { |f| f['key'] == key }
          list.reject! { |f| f['key'] == key }
          false
        else
          list.unshift(item.select { |k, _| ONLINE_FAV_KEYS.include?(k) })
          @data['online_favorites'] = sanitize_online_favs(list)
          true
        end
      end

      def save_category(cat)
        list = @data['categories_custom'].reject { |c| c['id'] == cat['id'] }
        list << cat
        @data['categories_custom'] = Categories.sanitize_custom(list)
        @data['categories_custom'].find { |c| c['name'] == Util.utf8(cat['name']).strip[0, 40] }
      end

      def delete_category(id)
        before = @data['categories_custom'].size
        @data['categories_custom'].reject! { |c| c['id'] == id.to_s }
        @data['ui']['category'] = 'all' if @data['ui']['category'] == id.to_s
        before != @data['categories_custom'].size
      end

      def public_hash
        deep_dup(@data)
      end

      private

      def migrate(raw)
        d = deep_dup(raw)
        unless d['schema'].is_a?(Integer)
          # Bản gốc: {'roots','favorites','history','model'}
          model = d.delete('model')
          d['ai'] ||= {}
          if model.is_a?(String) && !model.strip.empty? && !LEGACY_DEFAULT_MODELS.include?(model.strip)
            d['ai']['model'] = model.strip
          end
          d['schema'] = SCHEMA
        end
        d
      end

      def sanitize(raw)
        out = deep_dup(DEFAULTS)
        out['roots'] = str_list(raw['roots']).map { |r| Util.norm_path(r) }.reject(&:empty?).uniq { |r| Util.path_key(r) }
        out['favorites'] = id_list(raw['favorites']).first(FAVORITES_MAX)
        out['history'] = id_list(raw['history']).first(HISTORY_MAX)
        out['quick_scan'] = bool(raw['quick_scan'], true)
        out['scan_on_open'] = bool(raw['scan_on_open'], true)
        ui = raw['ui'].is_a?(Hash) ? raw['ui'] : {}
        ps = ui['page_size'].to_i
        out['ui']['page_size'] = [24, 48, 96, 150].include?(ps) ? ps : 48
        out['ui']['sort'] = SORTS.include?(ui['sort']) ? ui['sort'] : 'relevance'
        out['ui']['size_max_mb'] = [0, 5, 10, 20, 50, 100].include?(ui['size_max_mb'].to_i) ? ui['size_max_mb'].to_i : 0
        out['ui']['tab'] = %w[offline online favorites history settings].include?(ui['tab']) ? ui['tab'] : 'offline'
        ts = ui['thumb_size'].to_i
        out['ui']['thumb_size'] = ts.between?(120, 360) ? ts : 200
        out['ui']['filter'] = %w[all local online insertable free].include?(ui['filter']) ? ui['filter'] : 'all'
        out['ui']['category'] = ui['category'].to_s =~ /\A[a-z_0-9]{2,20}\z/ ? ui['category'].to_s : 'all'
        out['categories_custom'] = Categories.sanitize_custom(raw['categories_custom'])
        out['online_favorites'] = sanitize_online_favs(raw['online_favorites'])
        src = raw['sources'].is_a?(Hash) ? raw['sources'] : {}
        out['sources']['sketchfab'] = bool(src['sketchfab'], true)
        %w[polyhaven cgtips sketchupfree thuviensketchup].each { |k| out['sources'][k] = bool(src[k], true) }
        out['auto_save_downloads'] = bool(raw['auto_save_downloads'], true)
        cv = raw['converter'].is_a?(Hash) ? raw['converter'] : {}
        bp = Util.utf8(cv['blender_path']).strip
        out['converter']['blender_path'] = bp =~ /blender(\.exe)?\z/i ? Util.norm_path(bp) : ''
        out['converter']['blender_version'] = Util.utf8(cv['blender_version'])[0, 40]
        out['converter']['blender_ok'] = bool(cv['blender_ok'], false) && !out['converter']['blender_path'].empty?
        out['converter']['blender_reason'] = Util.utf8(cv['blender_reason'])[0, 300]
        to = cv['timeout'].to_i
        out['converter']['timeout'] = to.between?(60, 3600) ? to : 600
        out['converter']['gltf_engine'] = 'auto' # V1.0.6: luôn ưu tiên bộ đọc GLB/glTF tích hợp (không còn tùy chọn trên giao diện)
        ai = raw['ai'].is_a?(Hash) ? raw['ai'] : {}
        m = ai['model'].to_s.strip
        out['ai']['model'] = m =~ /\A[A-Za-z0-9._:\-\/]{2,80}\z/ ? m : DEFAULT_MODEL
        b = ai['base_url'].to_s.strip.sub(%r{/+\z}, '')
        out['ai']['base_url'] = b =~ %r{\Ahttps://[^\s]+\z} ? b : DEFAULTS['ai']['base_url']
        out['ai']['detail'] = %w[low high auto].include?(ai['detail']) ? ai['detail'] : 'low'
        out['ai']['remember_key'] = bool(ai['remember_key'], false)
        sf = raw['sketchfab'].is_a?(Hash) ? raw['sketchfab'] : {}
        out['sketchfab']['downloadable_only'] = bool(sf['downloadable_only'], true)
        out['sketchfab']['token_type'] = %w[token bearer].include?(sf['token_type']) ? sf['token_type'] : 'token'
        out['sketchfab']['remember_token'] = bool(sf['remember_token'], false)
        net = raw['net'].is_a?(Hash) ? raw['net'] : {}
        t = net['timeout'].to_i
        out['net']['timeout'] = t.between?(5, 180) ? t : 30
        up = raw['update'].is_a?(Hash) ? raw['update'] : {}
        out['update']['source'] = %w[none manifest github].include?(up['source']) ? up['source'] : 'none'
        mu = up['manifest_url'].to_s.strip
        out['update']['manifest_url'] = mu =~ %r{\Ahttps://\S+\z} ? mu : ''
        gr = up['github_repo'].to_s.strip
        out['update']['github_repo'] = gr =~ %r{\A[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+\z} ? gr : ''
        out['update']['check_on_start'] = bool(up['check_on_start'], false)
        out
      end

      def sanitize_online_favs(list)
        Array(list).select { |f| f.is_a?(Hash) && f['key'].to_s =~ /\A[a-z]+:[A-Za-z0-9_\-]{4,64}\z/ }.map do |f|
          h = f.select { |k, _| ONLINE_FAV_KEYS.include?(k) }
          %w[thumb thumb_large].each { |k| h[k] = nil unless h[k].to_s.start_with?('https://media.sketchfab.com/') }
          %w[url author_url].each { |k| h[k] = nil unless h[k].to_s =~ %r{\Ahttps://(www\.)?sketchfab\.com/} }
          %w[title author license source_label].each { |k| h[k] = Util.utf8(h[k]).strip[0, 200] if h[k] }
          h
        end.uniq { |f| f['key'] }.first(ONLINE_FAV_MAX)
      end

      def quarantine(exc)
        bad = "#{@path}.corrupt-#{Time.now.strftime('%Y%m%d%H%M%S')}"
        File.rename(@path, bad) if File.exist?(@path)
        @load_warning = "settings.json bị hỏng, đã chuyển sang #{File.basename(bad)} và dùng cấu hình mặc định."
        @logger&.error(@load_warning, exc)
        # Thử khôi phục từ bản .bak
        bak = "#{@path}.bak"
        return unless File.file?(bak)
        begin
          Util.read_json(bak)
          FileUtils.cp(bak, @path)
          @load_warning += ' Đã khôi phục từ bản sao lưu settings.json.bak.'
        rescue StandardError
          nil
        end
      rescue StandardError
        nil
      end

      def str_list(v)
        Array(v).select { |x| x.is_a?(String) }.map { |x| Util.utf8(x) }
      end

      def id_list(v)
        str_list(v).select { |x| x =~ /\A[0-9a-f]{64}\z/ }.uniq
      end

      def bool(v, default)
        v == true || v == false ? v : default
      end

      def deep_dup(o)
        JSON.parse(JSON.generate(o))
      end
    end
  end
end
