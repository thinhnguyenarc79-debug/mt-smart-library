# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Chuẩn hóa – lọc liên quan – loại trùng – xếp hạng – lọc hiển thị cho kết quả mọi nguồn.
    # Không ưu tiên website cụ thể: điểm chỉ dựa trên liên quan, danh mục, ảnh, quyền tải, SKP,
    # khả năng chèn ngay, chất lượng và dung lượng.
    module ResultRanker
      # Danh mục Sketchfab không phù hợp thư viện kiến trúc/nội thất (trừ khi người dùng hỏi rõ).
      EXCLUDED_CATS = %w[characters-creatures animals-pets people weapons-military].freeze
      EXCLUDED_CAT_WORDS = %w[character creature animal people weapon military].freeze
      FILTERS = %w[all local online web insertable free].freeze

      module_function

      # Kết quả online chỉ được giữ khi tên/tag khớp từ khóa (không chấp nhận khớp chỉ trong mô tả).
      def relevant_online?(item, query, cat_terms)
        hay = ' ' + Util.fold("#{item['title']} #{Array(item['tags']).join(' ')}") + ' '
        return false if item['age_restricted']
        cats = Array(item['cats']).map(&:to_s)
        unless user_asks_excluded?(query)
          return false if cats.any? { |c| EXCLUDED_CATS.include?(c) }
        end
        groups = QueryNormalizer.online_groups(query)
        unless groups.empty?
          mandatory = groups.select { |g| g['object'] }
          mandatory = groups.select { |g| g['has_en'] } if mandatory.empty?
          mandatory = groups if mandatory.empty?
          return false unless mandatory.all? { |g| g['alts'].any? { |a| hit?(hay, a) } }
        end
        return false if !cat_terms.empty? && cat_terms.none? { |a| hit?(hay, a) }
        true
      end

      def user_asks_excluded?(query)
        return false unless query && !query.empty?
        f = ' ' + query.folded + ' ' + query.primary_en.to_s + ' '
        EXCLUDED_CAT_WORDS.any? { |w| f.include?(" #{w}") } || f.include?(' nguoi ') || f.include?(' dong vat ')
      end

      def hit?(hay, alt)
        alt.length <= 3 ? hay.include?(" #{alt} ") || hay.include?(" #{alt}s ") : hay.include?(" #{alt}")
      end

      # Điểm liên quan 0..1 cho kết quả online theo tên/tag.
      def online_relevance(item, query)
        return 0.5 if query.nil? || query.empty?
        name = ' ' + Util.fold(item['title']) + ' '
        tags = ' ' + Util.fold(Array(item['tags']).join(' ')) + ' '
        groups = QueryNormalizer.online_groups(query)
        return 0.5 if groups.empty?
        s = groups.sum do |g|
          if g['alts'].any? { |a| hit?(name, a) } then 1.0
          elsif g['alts'].any? { |a| hit?(tags, a) } then 0.5
          else 0.0
          end
        end
        s / groups.size
      end

      def score(item, query, cat_terms)
        s = 0.0
        rel = item['source'] == 'local' ? item['rel'].to_f : online_relevance(item, query)
        s += 40 * rel
        if !cat_terms.empty?
          hay = ' ' + Util.fold("#{item['title']} #{Array(item['tags']).join(' ')}") + ' '
          s += 15 if cat_terms.any? { |a| hit?(hay, a) }
        end
        s += 5 if item['thumb'] || item['source'] == 'local'
        s += 5 if item['downloadable']
        s += 8 if item['format'] == 'skp'
        s += 8 if item['insertable']
        s += 4 if item['web_model'] && item['thumb']
        if item['source'] == 'local'
          mb = item['size'].to_i / 1_048_576.0
          s += mb <= 20 ? 4 : (mb > 80 ? -4 : 0)
        else
          likes = item['likes'].to_i
          s += [Math.log10(likes + 1) * 2, 6].min
          faces = item['faces'].to_i
          s += faces.positive? && faces <= 300_000 ? 3 : (faces > 1_500_000 ? -4 : 0)
        end
        s.round(2)
      end

      def dedupe_key(item)
        return "local:#{item['id']}" if item['source'] == 'local'
        "#{item['source']}:#{item['uid']}"
      end

      # Gộp trùng cùng tên + cùng tác giả giữa các kết quả online (bản đăng lại).
      def merge_into(store, items)
        added = 0
        names = {}
        store.each_value { |v| names[[Util.fold(v['title']), v['author'].to_s.downcase]] = true if v['source'] != 'local' }
        items.each do |it|
          k = dedupe_key(it)
          next if store.key?(k)
          if it['source'] != 'local' && !it['web_model'] # website: mỗi link chi tiết là 1 model riêng (khóa theo link)
            nk = [Util.fold(it['title']), it['author'].to_s.downcase]
            next if names[nk]
            names[nk] = true
          end
          it['key'] = k
          store[k] = it
          added += 1
        end
        added
      end

      def apply_filter(items, filter)
        case filter
        when 'local' then items.select { |i| i['source'] == 'local' }
        when 'online' then items.reject { |i| i['source'] == 'local' }
        when 'web' then items.select { |i| i['web_model'] }
        when 'insertable' then items.select { |i| i['insertable'] }
        when 'free' then items.select { |i| i['free'] }
        else items
        end
      end

      def rank(items)
        items.sort_by { |i| [-i['score'].to_f, i['title'].to_s.downcase] }
      end
    end
  end
end
