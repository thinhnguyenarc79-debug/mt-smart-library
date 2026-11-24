# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Từ điển đồng nghĩa Việt <-> Anh cho kiến trúc / nội thất.
    module Synonyms
      DICT = {
        'ghế' => %w[chair armchair seat], 'ghế sofa' => %w[sofa couch], 'sofa' => %w[sofa couch], 'sô pha' => %w[sofa couch],
        'ghế đôn' => %w[stool ottoman], 'đôn' => %w[stool ottoman pouf], 'ghế bar' => ['bar stool', 'bar chair'],
        'ghế ăn' => ['dining chair'], 'ghế văn phòng' => ['office chair'], 'ghế thư giãn' => ['lounge chair', 'recliner'],
        'bàn' => %w[table desk], 'bàn ăn' => ['dining table'], 'bàn trà' => ['coffee table', 'tea table'],
        'bàn làm việc' => ['desk', 'office desk', 'work table'], 'bàn trang điểm' => ['dressing table', 'vanity'],
        'bàn đầu giường' => %w[nightstand bedside], 'táp đầu giường' => %w[nightstand bedside], 'tab đầu giường' => %w[nightstand bedside],
        'giường' => %w[bed], 'đầu giường' => %w[headboard bedside], 'nệm' => %w[mattress], 'đệm' => %w[mattress cushion],
        'tủ' => %w[cabinet wardrobe closet cupboard], 'tủ áo' => %w[wardrobe closet], 'tủ quần áo' => %w[wardrobe closet],
        'tủ bếp' => ['kitchen cabinet'], 'tủ giày' => ['shoe cabinet', 'shoe rack'], 'tủ sách' => %w[bookcase bookshelf],
        'tủ tivi' => ['tv cabinet', 'tv stand'], 'kệ tivi' => ['tv cabinet', 'tv stand', 'tv unit'],
        'kệ' => %w[shelf shelves rack], 'giá sách' => %w[bookshelf bookcase],
        'đèn' => %w[lamp light lighting], 'đèn chùm' => %w[chandelier], 'đèn thả' => %w[pendant], 'đèn bàn' => ['table lamp'],
        'đèn cây' => ['floor lamp'], 'đèn tường' => ['wall lamp', 'sconce'], 'đèn âm trần' => %w[downlight spotlight],
        'cây' => %w[plant tree], 'cây xanh' => %w[plant tree], 'chậu cây' => %w[planter pot], 'hoa' => %w[flower],
        'rèm' => %w[curtain blind drape], 'thảm' => %w[carpet rug], 'gương' => %w[mirror],
        'tranh' => %w[painting picture artwork frame], 'khung tranh' => %w[frame], 'bình' => %w[vase], 'lọ hoa' => %w[vase],
        'gối' => %w[pillow cushion], 'chăn' => %w[blanket], 'đồng hồ' => %w[clock], 'sách' => %w[book],
        'đồ trang trí' => %w[decor decoration accessory], 'decor' => %w[decor decoration],
        'bồn cầu' => %w[toilet wc], 'lavabo' => %w[basin sink washbasin], 'chậu rửa' => %w[sink basin],
        'bồn tắm' => %w[bathtub tub], 'vòi sen' => %w[shower], 'vòi' => %w[faucet tap], 'bồn tiểu' => %w[urinal],
        'bếp' => %w[kitchen stove cooktop], 'tủ lạnh' => %w[fridge refrigerator], 'máy giặt' => ['washing machine', 'washer'],
        'lò vi sóng' => %w[microwave], 'lò nướng' => %w[oven], 'máy hút mùi' => ['hood', 'range hood'],
        'điều hòa' => ['air conditioner', 'aircon'], 'máy lạnh' => ['air conditioner', 'aircon'], 'quạt' => %w[fan],
        'tivi' => %w[tv television], 'ti vi' => %w[tv television], 'loa' => %w[speaker], 'máy tính' => %w[computer pc laptop],
        'piano' => %w[piano], 'đàn' => %w[piano guitar],
        'cửa' => %w[door], 'cửa sổ' => %w[window], 'cửa kính' => ['glass door'], 'cửa cuốn' => ['rolling door', 'shutter'],
        'cổng' => %w[gate], 'hàng rào' => %w[fence], 'cầu thang' => %w[stair stairs staircase],
        'lan can' => %w[railing balustrade handrail], 'tay vịn' => %w[handrail],
        'trần' => %w[ceiling], 'sàn' => %w[floor flooring], 'tường' => %w[wall], 'vách' => %w[partition wall], 'vách ngăn' => %w[partition divider],
        'cột' => %w[column pillar], 'mái' => %w[roof], 'ban công' => %w[balcony], 'lam' => %w[louver louvre],
        'gỗ' => %w[wood wooden timber], 'đá' => %w[stone marble granite], 'đá hoa cương' => %w[granite], 'cẩm thạch' => %w[marble],
        'kính' => %w[glass], 'kim loại' => %w[metal], 'sắt' => %w[iron steel], 'thép' => %w[steel], 'inox' => %w[stainless steel],
        'nhôm' => %w[aluminium aluminum], 'đồng' => %w[brass copper bronze], 'vải' => %w[fabric textile], 'da' => %w[leather],
        'nhựa' => %w[plastic], 'mây' => %w[rattan wicker], 'tre' => %w[bamboo], 'nhung' => %w[velvet], 'gạch' => %w[tile brick],
        'bê tông' => %w[concrete], 'tròn' => %w[round circular], 'vuông' => %w[square], 'chữ nhật' => %w[rectangular rectangle],
        'chữ l' => ['l shape', 'l shaped', 'corner'], 'góc' => %w[corner], 'đơn' => %w[single], 'đôi' => %w[double],
        'trắng' => %w[white], 'đen' => %w[black], 'xám' => %w[gray grey], 'nâu' => %w[brown], 'be' => %w[beige],
        'kem' => %w[cream], 'xanh' => %w[blue green], 'xanh dương' => %w[blue], 'xanh lá' => %w[green], 'đỏ' => %w[red],
        'vàng' => %w[yellow gold], 'hồng' => %w[pink], 'cam' => %w[orange], 'tím' => %w[purple violet],
        'hiện đại' => %w[modern contemporary], 'cổ điển' => %w[classic classical], 'tân cổ điển' => %w[neoclassical neoclassic],
        'tối giản' => %w[minimal minimalist], 'bắc âu' => %w[scandinavian nordic], 'công nghiệp' => %w[industrial],
        'đông dương' => %w[indochine], 'nhật' => %w[japanese japandi], 'luxury' => %w[luxury], 'sang trọng' => %w[luxury],
        'phòng khách' => ['living room', 'livingroom'], 'phòng ngủ' => %w[bedroom], 'phòng tắm' => %w[bathroom],
        'nhà vệ sinh' => %w[toilet restroom wc bathroom], 'wc' => %w[toilet restroom], 'phòng ăn' => ['dining room'],
        'văn phòng' => %w[office], 'ngoại thất' => %w[exterior outdoor], 'nội thất' => %w[interior furniture],
        'sân vườn' => %w[garden landscape], 'cảnh quan' => %w[landscape], 'hồ bơi' => ['pool', 'swimming pool'],
        'người' => %w[people human person], 'xe' => %w[car vehicle], 'ô tô' => %w[car], 'xe máy' => %w[motorbike motorcycle scooter],
        'xe đạp' => %w[bicycle bike], 'quầy' => %w[counter bar], 'quầy bar' => ['bar counter'], 'lễ tân' => %w[reception],
        'kệ bếp' => ['kitchen shelf'], 'bát đĩa' => %w[tableware dish dishes], 'cốc' => %w[cup mug], 'ly' => %w[glass cup],
        'công tắc' => %w[switch], 'ổ cắm' => %w[socket outlet]
      }.freeze

      class << self
        def accented
          @accented ||= DICT.each_with_object({}) do |(k, v), h|
            h[Util.lower_keep_accents(k)] = v.map { |x| Util.fold(x) }
          end
        end

        # Khóa đã bỏ dấu (gộp các khóa trùng như "da" = da/đá).
        def folded
          @folded ||= DICT.each_with_object({}) do |(k, v), h|
            fk = Util.fold(k)
            (h[fk] ||= []).concat(v.map { |x| Util.fold(x) })
            h[fk].uniq!
          end
        end

        # Anh -> các từ tiếng Việt (bỏ dấu).
        def reverse
          @reverse ||= DICT.each_with_object({}) do |(k, v), h|
            fk = Util.fold(k)
            v.each do |en|
              fe = Util.fold(en)
              (h[fe] ||= []) << fk unless (h[fe] ||= []).include?(fk)
            end
          end
        end

        # Biên dịch truy vấn thành các nhóm; item khớp khi mọi nhóm có ít nhất 1 phương án.
        def compile(query)
          words_acc = Util.lower_keep_accents(query).split(' ')
          groups = []
          i = 0
          while i < words_acc.size
            matched = false
            [4, 3, 2, 1].each do |n|
              next if i + n > words_acc.size
              phrase_acc = words_acc[i, n].join(' ')
              phrase_f = Util.fold(phrase_acc)
              alts = nil
              if accented.key?(phrase_acc)
                alts = accented[phrase_acc]
              elsif folded.key?(phrase_f)
                alts = folded[phrase_f]
              elsif reverse.key?(phrase_f)
                alts = reverse[phrase_f]
              end
              next if alts.nil? && n > 1
              list = [phrase_f]
              list.concat(alts) if alts
              list.concat(reverse[phrase_f]) if reverse.key?(phrase_f) && alts && !alts.equal?(reverse[phrase_f])
              groups << list.reject(&:empty?).uniq
              i += n
              matched = true
              break
            end
            i += 1 unless matched
          end
          groups.reject(&:empty?)
        end
      end
    end
  end
end
