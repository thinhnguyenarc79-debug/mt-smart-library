# frozen_string_literal: true
require 'uri'

module MTDesign
  module SmartLibrary
    # “Nhập link model”: người dùng dán link bài viết hoặc link tải (Facebook, Drive, Dropbox, MediaFire, Mega, OneDrive, website…).
    # - Link file trực tiếp (đuôi model/nén) hoặc link chia sẻ Dropbox (dl=1 theo hướng dẫn chính thức) → plugin tải và chèn.
    # - Còn lại (trang cần đăng nhập/xác minh/quảng cáo, file mã hóa phía trình duyệt) → mở trên trình duyệt, plugin tự nhận file vừa tải.
    # Không đọc nội dung trang, không vượt đăng nhập/CAPTCHA.
    module LinkImport
      FILE_EXT = /\.(skp|zip|glb|gltf|fbx|obj|dae|3ds|kmz|stl|usdz|ply|blend)\z/i.freeze
      MAX_BYTES = 1024 * 1024 * 1024

      module_function

      # → { kind: :download|:open, url:, service: }
      def classify(raw)
        url = raw.to_s.strip
        url = "https://#{url}" unless url =~ %r{\Ahttps?://}i
        u = URI.parse(url)
        raise 'Link không hợp lệ.' unless u.is_a?(URI::HTTP) && u.host.to_s.include?('.')
        u.scheme = 'https'
        host = u.host.downcase
        service = SourceRegistry.detect_type(u)
        if service == 'dropbox' && u.path =~ %r{\A/(s|scl/fi)/}
          q = URI.decode_www_form(u.query.to_s).reject { |k, _| %w[dl raw].include?(k) } << %w[dl 1]
          u.query = URI.encode_www_form(q)
          return { kind: :download, url: u.to_s, service: 'dropbox' }
        end
        if %w[website].include?(service) && u.path.to_s =~ FILE_EXT
          return { kind: :download, url: u.to_s, service: 'direct', host: host }
        end
        { kind: :open, url: u.to_s, service: service }
      rescue URI::InvalidURIError
        raise 'Link không hợp lệ.'
      end

      # Nhận diện thật loại file theo nội dung (không tin đuôi/tiêu đề): trả đuôi hoặc nil (trang HTML / không rõ).
      def sniff(path)
        head = File.binread(path, 64) || ''.b
        return '.zip' if head.start_with?("PK\x03\x04".b)
        return '.skp' if head.include?("S\x00k\x00e\x00t\x00c\x00h\x00U\x00p\x00".b)
        return '.glb' if head.start_with?('glTF'.b)
        return '.rar' if head.start_with?("Rar!\x1A\x07".b)
        return '.7z' if head.start_with?("7z\xBC\xAF\x27\x1C".b)
        return nil if head.lstrip =~ /\A<(!doctype|html|\?xml)/i
        nil
      end

      def filename_for(url)
        base = File.basename(URI.parse(url).path.to_s)
        base = 'model_download' if base.empty? || base == '/'
        Util.safe_filename(URI.decode_www_form_component(base))
      rescue StandardError
        'model_download'
      end
    end
  end
end
