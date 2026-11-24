# frozen_string_literal: true
require 'uri'

module MTDesign
  module SmartLibrary
    # Adapter "mở trang tìm kiếm chính thức trên trình duyệt". Không scrape, không giả lập API,
    # không vượt đăng nhập/CAPTCHA. Người dùng tự tải theo điều khoản của từng trang.
    module LinkSources
      SOURCES = {
        'warehouse' => { 'name' => '3D Warehouse', 'url' => 'https://3dwarehouse.sketchup.com/search/?q=%s',
                         'note' => 'Kho SKP chính thức của SketchUp' },
        'sketchfab_web' => { 'name' => 'Sketchfab (web)', 'url' => 'https://sketchfab.com/search?q=%s&type=models',
                             'note' => 'Mở trang Sketchfab' },
        '3dsky' => { 'name' => '3dsky', 'url' => 'https://3dsky.org/3dmodels?query=%s', 'note' => 'Chủ yếu 3ds Max' },
        'cgtrader' => { 'name' => 'CGTrader', 'url' => 'https://www.cgtrader.com/3d-models?keywords=%s',
                        'note' => 'Có lọc định dạng .skp trên trang' },
        'google' => { 'name' => 'Google (SKP)', 'url' => 'https://www.google.com/search?q=%s', 'suffix' => ' skp sketchup model',
                      'note' => 'Tìm rộng trên web' }
      }.freeze

      module_function

      def url_for(source, query)
        s = SOURCES[source.to_s]
        raise "Nguồn không hợp lệ: #{source}" unless s
        q = Util.utf8(query).strip
        raise 'Nhập từ khóa trước khi tìm online.' if q.empty?
        q = q[0, 200] + s['suffix'].to_s
        format(s['url'], URI.encode_www_form_component(q))
      end

      def list
        SOURCES.map { |k, v| { 'id' => k, 'name' => v['name'], 'note' => v['note'] } }
      end
    end
  end
end
