# frozen_string_literal: true
require 'uri'

module MTDesign
  module SmartLibrary
    # KÊNH CẬP NHẬT CHÍNH THỨC (GitHub công khai) — tích hợp sẵn trong plugin.
    # Máy mới cài RBZ: tự dùng kênh này, tự kiểm tra khi mở plugin, KHÔNG tự cài khi chưa được đồng ý.
    # Không cần URL, token hay tài khoản GitHub. Người dùng có nguồn riêng hợp lệ (URL khác, repo khác, LAN) được giữ nguyên.
    # Module thuần hàm (nạp lại nóng được) — sau này thay kênh/bổ sung bản quyền mà không sửa updater.
    module UpdateChannel
      REPO = 'thinhnguyenarc79-debug/mt-smart-library'
      LABEL = 'Kênh chính thức MT (GitHub)'
      # Thứ tự thử: asset của Release mới nhất (không giới hạn API) → manifest trên nhánh main (dự phòng).
      MANIFEST_URLS = [
        "https://github.com/#{REPO}/releases/latest/download/update_manifest.json",
        "https://raw.githubusercontent.com/#{REPO}/main/releases/update_manifest.json"
      ].freeze
      # Host được phép trong chuỗi tải gói của kênh chính thức (GitHub chuyển hướng asset sang CDN của GitHub).
      DOWNLOAD_HOSTS = %w[github.com objects.githubusercontent.com release-assets.githubusercontent.com
                          raw.githubusercontent.com].freeze

      module_function

      def release_page
        "https://github.com/#{REPO}/releases"
      end

      # URL thuộc repo chính thức (github.com/<repo>/releases/… hoặc raw.githubusercontent.com/<repo>/…).
      def official_url?(url)
        u = URI.parse(url.to_s)
        return false unless u.is_a?(URI::HTTPS) && u.host && !u.userinfo
        path = u.path.to_s
        case u.host.downcase
        when 'github.com' then path.start_with?("/#{REPO}/releases/")
        when 'raw.githubusercontent.com' then path.start_with?("/#{REPO}/")
        else false
        end
      rescue URI::InvalidURIError
        false
      end

      def download_host_ok?(url)
        u = URI.parse(url.to_s)
        u.is_a?(URI::HTTPS) && DOWNLOAD_HOSTS.include?(u.host.to_s.downcase)
      rescue URI::InvalidURIError
        false
      end

      # Cấu hình đang trỏ về kênh chính thức (kể cả cấu hình cũ: URL manifest/raw của repo chính thức, hoặc repo chính thức).
      def official_cfg?(up)
        return false unless up.is_a?(Hash)
        case up['source']
        when 'official' then true
        when 'manifest' then official_url?(up['manifest_url'])
        when 'github' then up['github_repo'].to_s.casecmp?(REPO)
        else false
        end
      end

      # Chuẩn hóa nguồn cập nhật khi nạp cài đặt:
      # - lần đầu: chưa cấu hình ('none') → 'official'; luôn: đang trỏ về repo chính thức → 'official';
      #   (sau đó người dùng chủ động chọn “Không dùng” thì giữ);
      # - nguồn riêng hợp lệ (URL khác, repo khác, LAN) → giữ nguyên;
      # - bật “tự kiểm tra khi mở” MỘT lần cho kênh chính thức (người dùng tắt sau đó thì giữ lựa chọn).
      def migrate(up)
        up = up.dup
        first = !up['auto_check_set'] # lần đầu chạy bản có kênh chính thức (máy mới hoặc vừa nâng cấp)
        up['source'] = 'official' if (up['source'] == 'none' && first) || official_cfg?(up)
        if first
          up['check_on_start'] = true if up['source'] == 'official'
          up['auto_check_set'] = true
        end
        up
      end
    end
  end
end
