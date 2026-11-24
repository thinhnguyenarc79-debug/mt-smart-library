# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    module Providers
      # Giao diện chung của mọi nguồn. Mỗi provider trả kết quả đã chuẩn hóa theo đợt:
      #   done.call('items' => [...], 'next' => token_hoặc_nil, 'error' => nil_hoặc_thông_báo)
      # Item chuẩn: key, source, source_label, title, thumb, thumb_large, author, author_url, license, url,
      #   insertable, downloadable, free, format, size, tags, cats, likes, faces, rel (0..1, chỉ local), ...
      class BaseProvider
        attr_reader :id, :label

        def initialize(id, label)
          @id = id
          @label = label
        end

        def online?
          false
        end

        # Có áp dụng cho phiên tìm này không (ví dụ: Lịch sử chỉ có dữ liệu máy tính).
        def applicable?(_session, _settings)
          true
        end

        def enabled?(_settings)
          true
        end

        def timeout
          15
        end

        def search(_session, _token, &_done)
          raise NotImplementedError
        end

        def cancel(_session); end

        # Mô tả trạng thái tích hợp cho màn hình Cài đặt › Nguồn tìm kiếm.
        def status_info(settings)
          { 'id' => id, 'name' => label, 'enabled' => enabled?(settings), 'integrated' => true, 'note' => '' }
        end
      end
    end
  end
end
