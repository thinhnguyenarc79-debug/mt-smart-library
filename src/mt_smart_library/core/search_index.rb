# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Chỉ mục tìm kiếm trong bộ nhớ: tìm ở Ruby, chỉ gửi 1 trang kết quả sang giao diện.
    class SearchIndex
      Entry = Struct.new(:id, :path, :name, :folder, :root, :size, :mtime, :hay, :name_f, :lname)

      attr_reader :generation

      def initialize
        @entries = []
        @by_id = {}
        @generation = 0
        @cache_key = nil
        @cache_ids = nil
      end

      def size
        @entries.size
      end

      def [](id)
        @by_id[id]
      end

      # Tạo entry (có thể gọi trong luồng nền: thuần Ruby).
      def self.build_entry(path, size, mtime, root)
        path = Util.utf8(path)
        base = File.basename(path)
        name = base.sub(/\.skp\z/i, '')
        dir = File.dirname(path)
        folder = File.basename(dir)
        rel = Util.under_root?(dir, root) ? dir[root.length..-1].to_s : dir
        name_f = Util.fold(name)
        hay = ' ' + [name_f, Util.fold(rel)].join(' ').squeeze(' ') + ' '
        Entry.new(Util.item_id(path), path, name, folder, root, size.to_i, mtime.to_i, hay, ' ' + name_f + ' ', name.downcase)
      end

      def replace(entries)
        @entries = entries
        @by_id = {}
        entries.each { |e| @by_id[e.id] = e }
        bump
      end

      def all_entries
        @entries
      end

      def entries_under(root)
        k = Util.path_key(root)
        @entries.select { |e| Util.path_key(e.root) == k }
      end

      def bump
        @generation += 1
        @cache_key = nil
        @cache_ids = nil
      end

      # opts: query, any_of(Array), tab(offline/favorites/history), favorites, history,
      #       size_max_mb, root, sort, page, per_page
      def search(opts)
        per = [[opts[:per_page].to_i, 1].max, 500].min
        ids = matching_ids(opts)
        total = ids.size
        pages = [(total + per - 1) / per, 1].max
        page = [[opts[:page].to_i, 0].max, pages - 1].min
        slice = ids[page * per, per] || []
        items = slice.map do |id|
          h = to_public(@by_id[id])
          h['score'] = @cache_scores[id] if opts[:with_score] && @cache_scores
          h
        end
        { 'total' => total, 'page' => page, 'pages' => pages, 'per_page' => per, 'items' => items, 'library_size' => @entries.size }
      end

      def to_public(e)
        { 'id' => e.id, 'name' => e.name, 'path' => e.path, 'folder' => e.folder, 'size' => e.size, 'mtime' => e.mtime }
      end

      private

      def matching_ids(opts)
        tab = opts[:tab].to_s
        favs = Array(opts[:favorites])
        hist = Array(opts[:history])
        must = Array(opts[:must_any]).map(&:to_s).reject(&:empty?)
        key = [@generation, opts[:query].to_s, Array(opts[:any_of]), tab, opts[:size_max_mb].to_i, opts[:root].to_s,
               opts[:sort].to_s, tab == 'favorites' ? favs.hash : 0, tab == 'history' ? hist.hash : 0, must]
        return @cache_ids if key == @cache_key && @cache_ids

        queries = Array(opts[:any_of]).map(&:to_s).reject { |q| q.strip.empty? }
        queries = [opts[:query].to_s] if queries.empty?
        compiled = queries.map { |q| Synonyms.compile(q) }.reject(&:empty?)
        base = candidates(tab, favs, hist)
        limit = opts[:size_max_mb].to_i * 1_048_576
        root_k = opts[:root].to_s.empty? ? nil : Util.path_key(opts[:root])
        scored = []
        base.each do |e|
          next if limit > 0 && e.size > limit
          next if root_k && Util.path_key(e.root) != root_k
          next if !must.empty? && must.none? { |a| hit?(e.hay, a) }
          if compiled.empty?
            scored << [e, 0]
            next
          end
          best = nil
          compiled.each do |groups|
            s = score(e, groups)
            best = s if s && (best.nil? || s > best)
          end
          scored << [e, best] if best
        end
        sort!(scored, opts[:sort].to_s, tab, hist, compiled.empty?)
        @cache_key = key
        @cache_scores = {}
        scored.each { |e, sc| @cache_scores[e.id] = sc }
        @cache_ids = scored.map { |x| x[0].id }
      end

      def candidates(tab, favs, hist)
        case tab
        when 'favorites' then favs.map { |id| @by_id[id] }.compact
        when 'history' then hist.map { |id| @by_id[id] }.compact
        else @entries
        end
      end

      def hit?(hay, alt)
        alt.length <= 3 ? hay.include?(' ' + alt) : hay.include?(alt)
      end

      # nil = không khớp; số càng lớn càng liên quan.
      def score(e, groups)
        s = 0
        groups.each_with_index do |alts, gi|
          in_name = alts.find { |a| hit?(e.name_f, a) }
          if in_name
            s += in_name.equal?(alts[0]) || in_name == alts[0] ? 12 : 8
            s += 3 if gi.zero? && e.name_f.start_with?(' ' + in_name)
            s += 3 if e.name_f.include?(' ' + in_name + ' ')
          elsif alts.any? { |a| hit?(e.hay, a) }
            s += 3
          else
            return nil
          end
        end
        s
      end

      def sort!(scored, sort, tab, hist, no_query)
        if tab == 'history' && (sort == 'relevance' || no_query)
          order = {}
          hist.each_with_index { |id, i| order[id] = i }
          scored.sort_by! { |e, _| order[e.id] || 1_000_000 }
          return
        end
        case sort
        when 'name' then scored.sort_by! { |e, _| e.lname }
        when 'name_desc' then scored.sort_by! { |e, _| e.lname }.reverse!
        when 'small' then scored.sort_by! { |e, _| [e.size, e.lname] }
        when 'large' then scored.sort_by! { |e, _| [-e.size, e.lname] }
        when 'new' then scored.sort_by! { |e, _| [-e.mtime, e.lname] }
        when 'old' then scored.sort_by! { |e, _| [e.mtime, e.lname] }
        else scored.sort_by! { |e, sc| [-sc, e.lname] }
        end
      end
    end
  end
end
