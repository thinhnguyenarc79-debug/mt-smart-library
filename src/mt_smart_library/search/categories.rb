# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Danh mục thanh bên trái. Danh mục mặc định cố định; danh mục tùy chỉnh lưu trong settings.json.
    module Categories
      DEFAULTS = [
        { 'id' => 'all', 'name' => 'Tất cả', 'kind' => 'all', 'icon' => '▦' },
        { 'id' => 'sofa', 'name' => 'Sofa', 'icon' => '🛋', 'en' => %w[sofa couch], 'vi' => ['sofa', 'sô pha', 'ghế sofa', 'văng'] },
        { 'id' => 'chair', 'name' => 'Ghế', 'icon' => '🪑', 'en' => %w[chair armchair stool seat], 'vi' => ['ghế', 'đôn'] },
        { 'id' => 'table', 'name' => 'Bàn', 'icon' => '◧', 'en' => %w[table desk], 'vi' => ['bàn'] },
        { 'id' => 'storage', 'name' => 'Tủ kệ', 'icon' => '▤', 'en' => %w[cabinet wardrobe shelf bookcase sideboard cupboard dresser],
          'vi' => ['tủ', 'kệ', 'giá sách'] },
        { 'id' => 'bed', 'name' => 'Giường', 'icon' => '🛏', 'en' => %w[bed], 'vi' => ['giường'] },
        { 'id' => 'lighting', 'name' => 'Đèn', 'icon' => '💡', 'en' => %w[lamp light chandelier pendant sconce], 'vi' => ['đèn'] },
        { 'id' => 'plant', 'name' => 'Cây xanh', 'icon' => '🌿', 'en' => %w[plant tree flower], 'vi' => ['cây', 'hoa', 'chậu cây'] },
        { 'id' => 'kitchen', 'name' => 'Đồ bếp', 'icon' => '🍳', 'en' => %w[kitchen stove fridge refrigerator hood oven cooktop microwave],
          'vi' => ['bếp', 'tủ lạnh', 'máy hút mùi', 'lò'] },
        { 'id' => 'bath', 'name' => 'Thiết bị vệ sinh', 'icon' => '🚿', 'en' => %w[toilet basin washbasin bathtub shower faucet sink],
          'vi' => ['bồn cầu', 'lavabo', 'bồn tắm', 'vòi sen', 'vòi', 'chậu rửa'] },
        { 'id' => 'curtain', 'name' => 'Rèm cửa', 'icon' => '🪟', 'en' => %w[curtain blind drape], 'vi' => ['rèm'] },
        { 'id' => 'decor', 'name' => 'Trang trí', 'icon' => '🖼', 'en' => %w[decor decoration vase painting mirror rug carpet pillow cushion clock frame],
          'vi' => ['trang trí', 'bình', 'tranh', 'gương', 'thảm', 'gối', 'đồng hồ'] },
        { 'id' => 'exterior', 'name' => 'Ngoại thất', 'icon' => '🏡', 'en' => %w[exterior outdoor garden fence gate pergola],
          'vi' => ['ngoại thất', 'sân vườn', 'hàng rào', 'cổng'] },
        { 'id' => 'personal', 'name' => 'Thư viện cá nhân', 'kind' => 'local', 'icon' => '💻' },
        { 'id' => 'favorites', 'name' => 'Yêu thích', 'kind' => 'favorites', 'icon' => '♥' },
        { 'id' => 'history', 'name' => 'Lịch sử', 'kind' => 'history', 'icon' => '🕘' }
      ].freeze
      MAX_CUSTOM = 40

      module_function

      def all(custom)
        list = DEFAULTS.map(&:dup)
        idx = list.index { |c| c['id'] == 'personal' }
        list.insert(idx, *Array(custom).map { |c| c.merge('custom' => true, 'icon' => '◆') })
        list
      end

      def find(id, custom)
        all(custom).find { |c| c['id'] == id.to_s } || DEFAULTS[0]
      end

      # Từ khóa đã bỏ dấu dùng để lọc (local + kiểm tra liên quan online).
      def terms(cat)
        return [] unless cat
        if cat['custom']
          Array(cat['keywords']).flat_map do |k|
            q = QueryNormalizer.analyze(k)
            [Util.fold(k)] + q.groups.flatten
          end.reject(&:empty?).uniq
        else
          (Array(cat['en']) + Array(cat['vi'])).map { |k| Util.fold(k) }.reject(&:empty?).uniq
        end
      end

      # Cụm tiếng Anh để tìm online khi chỉ chọn danh mục (không gõ từ khóa).
      def online_query(cat)
        return nil unless cat
        if cat['custom']
          k = Array(cat['keywords']).first
          k ? QueryNormalizer.analyze(k).primary_en : nil
        else
          Array(cat['en']).first
        end
      end

      def sanitize_custom(list)
        Array(list).select { |c| c.is_a?(Hash) }.map do |c|
          name = Util.utf8(c['name']).strip[0, 40]
          kws = Array(c['keywords']).map { |k| Util.utf8(k).strip[0, 60] }.reject(&:empty?).uniq.first(20)
          id = c['id'].to_s =~ /\Ac_[a-z0-9]{4,16}\z/ ? c['id'].to_s : "c_#{rand(36**8).to_s(36).rjust(8, '0')}"
          next if name.empty? || kws.empty?
          { 'id' => id, 'name' => name, 'keywords' => kws }
        end.compact.uniq { |c| c['id'] }.first(MAX_CUSTOM)
      end
    end
  end
end
