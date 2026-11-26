# frozen_string_literal: true
require 'uri'
module MTDesign
  module SmartLibrary
    module TeamConfig
      module_function
      FORMAT = 'mt-smart-library-team'
      # Không chuyển đường dẫn cá nhân, thông tin đăng nhập, lịch sử, dữ liệu bí mật.
      def export(settings, sources)
        h = settings.public_hash
        { 'format' => FORMAT, 'schema' => 1, 'settings' => safe_settings(h),
          'categories' => h['categories_custom'], 'sources' => safe_sources(sources.custom) }
      end

      def safe_url(value)
        u = URI.parse(value.to_s)
        return '' unless u.is_a?(URI::HTTPS) && u.host && !u.userinfo && !u.query && !u.fragment
        u.to_s
      rescue URI::InvalidURIError
        ''
      end

      def safe_settings(h)
        raise 'Cấu hình không hợp lệ.' unless h.is_a?(Hash)
        out = h.slice('quick_scan', 'scan_on_open', 'auto_save_downloads', 'visual_mode')
        out['sources'] = h['sources'].slice('sketchfab', 'polyhaven', 'cgtips', 'sketchupfree', 'thuviensketchup') if h['sources'].is_a?(Hash)
        if h['search'].is_a?(Hash)
          out['search'] = h['search'].slice('order', 'enabled')
          out['search']['searxng_url'] = safe_url(h['search']['searxng_url'])
        end
        if h['update'].is_a?(Hash)
          out['update'] = h['update'].slice('source', 'github_repo', 'lan_folder', 'check_on_start')
          out['update']['manifest_url'] = safe_url(h['update']['manifest_url'])
        end
        out['ai'] = { 'device' => 'cpu' }
        out
      end

      def safe_sources(list)
        Array(list).first(300).filter_map do |s|
          next unless s.is_a?(Hash) && s['type'] != 'local'
          url = safe_url(s['url'])
          next if url.empty?
          s.slice('name', 'type', 'enabled').merge('url' => url)
        end
      end

      def import(data, settings, sources)
        raise 'Không đúng định dạng cấu hình công ty.' unless data.is_a?(Hash) && data['format'] == FORMAT && data['schema'] == 1 && data['settings'].is_a?(Hash) && data['sources'].is_a?(Array)
        patch = safe_settings(data['settings'])
        # Sao lưu settings/sources theo cơ chế atomic_write có sẵn.
        settings.apply_ui(patch)
        Array(data['categories']).first(100).each { |c| settings.save_category(c) if c.is_a?(Hash) && c['id'].is_a?(String) }
        raise 'Không ghi được cấu hình.' unless settings.save
        sources.import_json(JSON.generate('sources' => safe_sources(data['sources'])))
      end
    end
  end
end
