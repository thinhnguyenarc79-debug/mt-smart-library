# frozen_string_literal: true
# MT SMART LIBRARY PRO — điểm vào của extension (được SketchupExtension nạp 1 lần).
require 'sketchup.rb'

module MTDesign
  module SmartLibrary
    CODE_DIR = File.dirname(__FILE__).dup.force_encoding('UTF-8') unless const_defined?(:CODE_DIR)

    %w[
      updater/version
      core/util core/paths core/logger core/settings core/synonyms core/search_index core/indexer
      core/thumbs core/inserter core/secret_store
      net/http_client online/link_sources online/sketchfab online/polyhaven online/wp_sources sources/source_registry sources/site_probe sources/link_import sources/fb_capture accounts/account_manager core/download_watcher ai/vision
      search/query_normalizer search/categories search/result_cache search/result_ranker
      search/providers/base_provider search/providers/local_provider search/providers/sketchfab_provider search/providers/polyhaven_provider search/providers/wp_provider search/providers/catalog_provider
      search/search_manager importers/gltf_importer
      convert/blender_runner convert/blender_detector convert/model_cache convert/converter_manager convert/import_manager
      ai_runtime/worker_lane ai_runtime/runtime_manager visual_search/visual_search_manager
      updater/zip_reader updater/backup_manager updater/hot_reload updater/updater
      ui/app
    ].each { |f| require File.join(CODE_DIR, f) }

    Paths.code_dir = CODE_DIR

    def self.open_library
      App.instance.show
    rescue StandardError => e
      UI.messagebox("#{PRODUCT_NAME}: không mở được thư viện.\n#{e.message}")
    end

    def self.open_updater
      App.instance.show_updater
    rescue StandardError => e
      UI.messagebox("#{PRODUCT_NAME}: không mở được trình cập nhật.\n#{e.message}")
    end

    def self.open_support
      App.instance.show_support
    rescue StandardError => e
      UI.messagebox("#{PRODUCT_NAME}: không mở được bảng hỗ trợ.\n#{e.message}")
    end

    def self.icon(name)
      File.join(CODE_DIR, 'icons', name)
    end

    # Menu/toolbar chỉ tạo 1 lần cho mỗi phiên SketchUp (chống trùng khi file bị nạp lại).
    unless file_loaded?(__FILE__)
      cmd_lib = UI::Command.new('Mở thư viện') { open_library }
      cmd_lib.tooltip = "#{PRODUCT_NAME} #{VERSION}"
      cmd_lib.status_bar_text = 'Thư viện model 3D Offline/Online và tìm kiếm AI'
      cmd_lib.small_icon = icon('library_24.png')
      cmd_lib.large_icon = icon('library_32.png')

      cmd_up = UI::Command.new('Cập nhật / Khôi phục phiên bản') { open_updater }
      cmd_up.tooltip = "Cập nhật #{PRODUCT_NAME} (đang dùng #{VERSION})"
      cmd_up.status_bar_text = 'Cài bản cập nhật từ file RBZ/ZIP hoặc online, khôi phục phiên bản trước'
      cmd_up.small_icon = icon('update_24.png')
      cmd_up.large_icon = icon('update_32.png')

      menu = UI.menu('Extensions').add_submenu(PRODUCT_NAME)
      menu.add_item(cmd_lib)
      menu.add_item(cmd_up)
      menu.add_separator
      menu.add_item('Hỗ trợ kỹ thuật…') { open_support }

      tb = UI::Toolbar.new(PRODUCT_NAME)
      tb.add_item(cmd_lib)
      tb.add_item(cmd_up)
      if defined?(TB_NEVER_SHOWN) && tb.get_last_state == TB_NEVER_SHOWN
        tb.show
      else
        tb.restore
      end

      begin
        app = App.instance
        app.schedule_startup_check
        if (msg = app.instance_variable_get(:@startup_msg))
          UI.start_timer(3, false) { Sketchup.status_text = "#{PRODUCT_NAME}: #{msg}" }
        end
      rescue StandardError => e
        puts "[MT Smart Library] Khởi tạo lỗi: #{e.message}"
      end

      file_loaded(__FILE__)
    end
  end
end
