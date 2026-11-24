# frozen_string_literal: true
# MT SMART LIBRARY PRO — loader (đặt trong thư mục Plugins của SketchUp).
require 'sketchup.rb'
require 'extensions.rb'
require File.join(File.dirname(__FILE__).dup.force_encoding('UTF-8'), 'mt_smart_library', 'updater', 'version')

module MTDesign
  module SmartLibrary
    unless file_loaded?(__FILE__)
      ext = SketchupExtension.new(PRODUCT_NAME, 'mt_smart_library/main')
      ext.version = VERSION
      ext.creator = 'MT Design (Kiến trúc & Nội thất Mạnh Trường)'
      ext.copyright = "© #{BUILD_DATE[0, 4]} MT Design"
      ext.description = 'Quản lý thư viện SKP offline, tìm kiếm online (3D Warehouse, Sketchfab…), ' \
                        'AI gợi ý từ khóa từ ảnh và hệ thống cập nhật MT SMART UPDATE. ID: ' + PLUGIN_ID
      Sketchup.register_extension(ext, true)
      file_loaded(__FILE__)
    end
  end
end
