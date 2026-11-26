# frozen_string_literal: true
require 'uri'

module MTDesign
  module SmartLibrary
    # Trạng thái tài khoản của từng nguồn thư viện (Cài đặt › Tài khoản thư viện).
    # Không thu thập mật khẩu, không đọc cookie trình duyệt. Đăng nhập luôn diễn ra trên trang chính thức;
    # plugin chỉ giữ API token người dùng tự dán (bộ nhớ phiên hoặc Windows DPAPI).
    module AccountManager
      STATUS = {
        'connected' => 'Đã kết nối',
        'not_logged_in' => 'Chưa đăng nhập',
        'no_login' => 'Không cần đăng nhập',
        'expired' => 'Phiên đăng nhập hết hạn',
        'need_api' => 'Cần cấp quyền API',
        'web_search' => 'Tìm qua công cụ tìm kiếm web — tự đăng nhập/tải trên trang',
        'unverified' => 'Chưa xác minh phương thức tích hợp'
      }.freeze

      # method: public | token | oauth | web — cách plugin truy cập nguồn.
      SOURCES = [
        { 'id' => 'sketchfab', 'name' => 'Sketchfab', 'method' => 'token', 'site' => 'https://sketchfab.com',
          'login_url' => 'https://sketchfab.com/settings/password',
          'note' => 'Tìm kiếm công khai. Tải model cần API token (Sketchfab › Settings › Password & API).' },
        { 'id' => 'polyhaven', 'name' => 'Poly Haven', 'method' => 'public', 'site' => 'https://polyhaven.com',
          'note' => 'API công khai, miễn phí CC0. Tìm, tải và chèn tự động.' },
        { 'id' => 'cgtips', 'name' => 'SketchUp CGTips', 'method' => 'public', 'site' => 'https://sketchup.cgtips.org',
          'note' => 'Tìm kiếm qua WordPress REST API công khai. Tải trên trang; plugin nhận file vừa tải và chèn.' },
        { 'id' => 'sketchupfree', 'name' => 'SketchupFree', 'method' => 'public', 'site' => 'https://sketchupfree.com',
          'note' => 'Tìm kiếm qua WordPress REST API công khai. Tải trên trang (có xác minh chống bot); plugin nhận file và chèn.' },
        { 'id' => 'thuviensketchup', 'name' => 'Thư viện SketchUp (thuviensketchup.vn)', 'method' => 'web', 'site' => 'https://thuviensketchup.vn',
          'login_url' => 'https://thuviensketchup.vn',
          'note' => 'Tìm kiếm công khai. Gói model trả phí: đăng nhập, mua và tải trên trang; plugin nhận file vừa tải và chèn.' },
        { 'id' => 'cgtrader', 'name' => 'CGTrader', 'method' => 'oauth', 'site' => 'https://www.cgtrader.com',
          'login_url' => 'https://www.cgtrader.com/developers',
          'note' => 'Có API chính thức (GET /v1/models, tải file) nhưng cần OAuth client ID/secret do CGTrader cấp. ' \
                    'Đăng nhập CGTrader và gửi yêu cầu cấp API tại trang Developers.' },
        { 'id' => 'warehouse', 'name' => '3D Warehouse', 'method' => 'web', 'site' => 'https://3dwarehouse.sketchup.com',
          'note' => 'Tìm qua công cụ tìm kiếm web (site:3dwarehouse.sketchup.com/model) — không dùng API nội bộ. Bấm MỞ TRANG, tự đăng nhập/tải SKP.' },
        { 'id' => '3dsky', 'name' => '3dsky', 'method' => 'web', 'site' => 'https://3dsky.org',
          'note' => 'Tìm qua công cụ tìm kiếm web, ảnh đại diện từ og:image công khai. Model chủ yếu 3ds Max; tự đăng nhập/tải trên trang.' },
        { 'id' => '3dbox', 'name' => '3dbox', 'method' => 'web', 'site' => 'https://3dbox.cc',
          'note' => 'Tìm qua công cụ tìm kiếm web (link /detail/), không gọi /api/. SKP miễn phí/trả phí bằng credit — tự đăng nhập/tải trên trang.' },
        { 'id' => 'sketchshaper', 'name' => 'Sketch Shaper', 'method' => 'web', 'site' => 'https://www.sketchshaper.com',
          'note' => 'Tìm qua công cụ tìm kiếm web (link model chi tiết), không gọi /api/. Tải SKP trên trang.' },
        { 'id' => 'tailieukientruc', 'name' => 'Tài liệu kiến trúc', 'method' => 'web', 'site' => 'https://tailieukientruc.net',
          'note' => 'Tìm qua công cụ tìm kiếm web (tiếng Việt + Anh). Tải bằng điểm, cần tài khoản — tự đăng nhập/tải trên trang.' },
        { 'id' => 'sketchupvn', 'name' => 'sketchup.vn', 'method' => 'web', 'site' => 'https://sketchup.vn',
          'note' => 'Tìm qua chỉ mục của công cụ tìm kiếm web. Trang báo lỗi 500 khi kiểm tra 26/11/2026 — link có thể chưa mở được.' }
      ].freeze

      INTEGRATED = %w[sketchfab polyhaven cgtips sketchupfree thuviensketchup warehouse 3dsky 3dbox sketchshaper tailieukientruc sketchupvn].freeze
      WEB_SEARCH = %w[warehouse 3dsky 3dbox sketchshaper tailieukientruc sketchupvn].freeze

      module_function

      def hosts
        SOURCES.flat_map { |s| [s['site'], s['login_url']] }.compact.map { |u| URI.parse(u).host.downcase }.uniq
      end

      # state: { 'sketchfab_token' => bool, 'sketchfab_expired' => bool }
      def list(state)
        SOURCES.map do |s|
          st = case s['id']
               when 'sketchfab'
                 if state['sketchfab_expired'] then 'expired'
                 elsif state['sketchfab_token'] then 'connected'
                 else 'not_logged_in'
                 end
               when 'polyhaven', 'cgtips', 'sketchupfree' then 'no_login'
               when 'thuviensketchup' then 'no_login'
               when *WEB_SEARCH then 'web_search'
               when 'cgtrader' then 'need_api'
               else 'unverified'
               end
          actions = []
          if s['id'] == 'sketchfab'
            actions << (st == 'connected' ? 'logout' : 'login')
            actions << 'reconnect' if st == 'expired'
          elsif s['login_url']
            actions << 'login'
          end
          actions << 'open'
          s.merge('status' => st, 'status_label' => STATUS[st], 'integrated' => INTEGRATED.include?(s['id']), 'actions' => actions)
        end
      end

      def url_for(id, action)
        s = SOURCES.find { |x| x['id'] == id.to_s }
        return nil unless s
        action.to_s == 'open' ? s['site'] : (s['login_url'] || s['site'])
      end
    end
  end
end
