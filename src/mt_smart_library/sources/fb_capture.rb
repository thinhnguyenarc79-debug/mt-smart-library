# frozen_string_literal: true
require 'json'

module MTDesign
  module SmartLibrary
    # FACEBOOK — ĐĂNG NHẬP THỦ CÔNG & LƯU BÀI ĐANG XEM.
    # Mở nhóm trong một cửa sổ riêng của plugin; NGƯỜI DÙNG tự đăng nhập (plugin không thấy/không lưu mật khẩu, không đọc cookie).
    # Plugin gắn một thanh nhỏ “MT: Lưu bài đang hiển thị”: chỉ khi người dùng bấm mới đọc các bài ĐANG HIỂN THỊ trên màn hình
    # (nội dung, ảnh, link bài, link tải). Không tự cuộn, không tự mở trang, không chạy nền, không vượt xác minh/CAPTCHA.
    class FbCapture
      MAX_JSON = 4 * 1024 * 1024
      JS = File.read(File.join(__dir__, 'fb_capture.js'), encoding: 'UTF-8').freeze

      def initialize(on_posts:, on_title:, logger: nil)
        @on_posts = on_posts
        @on_title = on_title
        @log = logger
        @dlg = nil
        @timer = nil
        @source_id = nil
      end

      def open(source)
        @source_id = source['id']
        if @dlg && @dlg.visible?
          @dlg.set_url(source['url'])
          @dlg.bring_to_front
        else
          @dlg = build(source)
          @dlg.set_url(source['url'])
          @dlg.show
        end
        start_timer
      end

      def notify(msg)
        @dlg.execute_script("window.__mtfb && window.__mtfb.notify(#{msg.to_s.to_json})") if @dlg && @dlg.visible?
      rescue StandardError
        nil
      end

      def close
        stop_timer
        @dlg&.close
      end

      private

      def build(source)
        d = UI::HtmlDialog.new(dialog_title: "MT SMART LIBRARY PRO — #{source['name']}", preferences_key: 'mtdesign_slp_fb',
                               width: 1100, height: 820, min_width: 700, min_height: 500, style: UI::HtmlDialog::STYLE_DIALOG)
        d.add_action_callback('mt_fb_capture') do |_ctx, json|
          begin
            raw = json.to_s
            raise 'Dữ liệu quá lớn.' if raw.bytesize > MAX_JSON
            data = JSON.parse(raw)
            @on_posts.call(@source_id, data.is_a?(Hash) ? data : {})
          rescue StandardError => e
            @log&.warn("Lưu bài Facebook lỗi: #{e.message}")
            notify("Lỗi: #{e.message}")
          end
        end
        d.add_action_callback('mt_fb_title') do |_ctx, t|
          begin
            @on_title.call(@source_id, t.to_s)
          rescue StandardError
            nil
          end
        end
        d.set_on_closed { stop_timer }
        d
      end

      # Gắn lại thanh lưu bài sau mỗi lần trang Facebook tự chuyển trang (ứng dụng một trang). Một timer duy nhất.
      def start_timer
        return if @timer
        @timer = UI.start_timer(2.0, true) do
          if @dlg && @dlg.visible?
            begin
              @dlg.execute_script(JS)
            rescue StandardError
              nil
            end
          else
            stop_timer
          end
        end
      end

      def stop_timer
        UI.stop_timer(@timer) if @timer
        @timer = nil
      end
    end
  end
end
