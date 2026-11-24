# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Chuẩn hóa truy vấn: tiếng Việt có/không dấu, tách cụm theo từ điển nội bộ, dịch sang tiếng Anh,
    # mở rộng từ khóa. Không gọi AI cho các từ thông dụng.
    module QueryNormalizer
      # Mở rộng từ khóa tiếng Anh (dùng hiển thị gợi ý, mở rộng tìm kiếm và kiểm tra liên quan).
      EXPANSIONS = {
        'sofa' => ['couch', 'modern sofa', 'living room sofa'],
        'couch' => ['sofa'],
        'chair' => ['armchair', 'dining chair', 'lounge chair'],
        'armchair' => ['chair', 'lounge chair'],
        'stool' => ['bar stool', 'ottoman'],
        'table' => ['dining table', 'coffee table', 'side table'],
        'desk' => ['office desk', 'work table'],
        'dining table' => ['table', 'dining set'],
        'coffee table' => ['table', 'tea table'],
        'bed' => ['double bed', 'bedroom bed', 'king bed'],
        'cabinet' => ['wardrobe', 'sideboard', 'cupboard'],
        'wardrobe' => ['closet', 'cabinet'],
        'shelf' => ['bookshelf', 'shelving', 'rack'],
        'lamp' => ['pendant lamp', 'floor lamp', 'table lamp'],
        'chandelier' => ['pendant lamp', 'ceiling lamp'],
        'plant' => ['indoor plant', 'potted plant', 'tree'],
        'tree' => ['plant'],
        'curtain' => ['drape', 'blinds'],
        'toilet' => ['wc', 'toilet bowl'],
        'basin' => ['washbasin', 'sink'],
        'bathtub' => ['bath tub', 'bath'],
        'kitchen' => ['kitchen cabinet', 'kitchen set'],
        'mirror' => ['wall mirror'],
        'rug' => ['carpet'],
        'carpet' => ['rug'],
        'vase' => ['flower vase'],
        'door' => ['interior door', 'wooden door'],
        'window' => ['window frame']
      }.freeze

      # Danh từ "đồ vật chính": kết quả online BẮT BUỘC khớp nhóm này (tránh khớp chỉ màu/vật liệu).
      OBJECT_NOUNS = %w[sofa couch chair armchair stool seat ottoman table desk bed cabinet wardrobe closet cupboard shelf shelves rack
                        bookcase bookshelf sideboard dresser lamp light lighting chandelier pendant sconce downlight plant tree flower
                        planter pot curtain blind drape carpet rug mirror painting picture vase pillow cushion clock frame toilet wc
                        basin sink washbasin bathtub tub shower faucet tap kitchen stove cooktop fridge refrigerator oven microwave hood
                        door window stair stairs staircase railing fence gate pergola pool tv television piano bench counter bar
                        nightstand bedside headboard mattress partition column fan speaker computer car].freeze

      Query = Struct.new(:raw, :folded, :groups, :parts, :primary_en, :expansions, :object_index) do
        def empty?
          folded.to_s.strip.empty?
        end
      end

      module_function

      def ascii?(s)
        s.to_s.ascii_only?
      end

      # parts: [{text:, en:[], vi:[], object:bool}] ; groups: mảng phương án (đã bỏ dấu) cho tìm local.
      def analyze(text)
        raw = Util.utf8(text).strip[0, 200]
        words = Util.lower_keep_accents(raw).split(' ')
        parts = []
        i = 0
        while i < words.size
          step = 1
          part = nil
          [4, 3, 2, 1].each do |n|
            next if i + n > words.size
            acc = words[i, n].join(' ')
            f = Util.fold(acc)
            next if f.empty?
            if Synonyms.accented.key?(acc)
              part = { 'text' => f, 'en' => Synonyms.accented[acc].dup, 'vi' => [f] }
            elsif Synonyms.folded.key?(f) && !ascii_english?(acc)
              part = { 'text' => f, 'en' => Synonyms.folded[f].dup, 'vi' => [f] }
            elsif Synonyms.reverse.key?(f) || (n == 1 && ascii?(acc))
              part = { 'text' => f, 'en' => [f], 'vi' => (Synonyms.reverse[f] || []).dup }
            elsif n == 1
              part = { 'text' => f, 'en' => [], 'vi' => [f] }
            end
            next unless part
            step = n
            break
          end
          parts << part if part
          i += step
        end
        parts.each { |p| p['en'].uniq!; p['object'] = p['en'].any? { |e| OBJECT_NOUNS.include?(e.split(' ').last) } }
        groups = parts.map { |p| ([p['text']] + p['en'] + p['vi']).reject(&:empty?).uniq }
        en_words = parts.map { |p| p['en'].first }.compact
        primary = en_words.join(' ').strip
        primary = Util.fold(raw) if primary.empty?
        exp = []
        parts.each do |p|
          p['en'].each do |e|
            exp << e
            exp.concat(EXPANSIONS[e] || [])
          end
        end
        exp = ([primary] + exp).map(&:strip).reject(&:empty?).uniq.first(8)
        obj = parts.index { |p| p['object'] }
        Query.new(raw, Util.fold(raw), groups, parts, primary, exp, obj)
      end

      # Từ tiếng Anh thuần (không phải khóa tiếng Việt không dấu như "ban", "ghe").
      def ascii_english?(acc)
        return false unless ascii?(acc)
        Synonyms.reverse.key?(Util.fold(acc))
      end

      # Nhóm điều kiện để kiểm tra liên quan cho kết quả online (tên + tag).
      def online_groups(query)
        return [] if query.nil? || query.empty?
        query.parts.map do |p|
          alts = (p['en'] + [p['text']] + p['en'].flat_map { |e| EXPANSIONS[e] || [] }).map { |x| Util.fold(x) }.reject(&:empty?).uniq
          { 'alts' => alts, 'object' => p['object'], 'has_en' => !p['en'].empty? }
        end
      end
    end
  end
end
