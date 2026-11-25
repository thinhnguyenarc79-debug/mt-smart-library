# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    module Providers
      # Kho dữ liệu tích lũy (SQLite): model đã trích xuất từ các nguồn người dùng nhập.
      # Tìm theo từ khóa Việt/Anh (đã bỏ dấu) — không cần mạng; kết quả có link tải/link bài viết đã trích xuất.
      class CatalogProvider < BaseProvider
        def initialize(runtime, settings_source_ids)
          super('catalog', 'Kho dữ liệu')
          @rt = runtime
          @disabled = settings_source_ids
          @jobs = {}
        end

        def online?
          false
        end

        def applicable?(session, _settings)
          return false if %w[history local favorites].include?(session.kind)
          @rt.available? && (!session.query.empty? || !session.any_of.empty?)
        end

        def search(session, token, &done)
          return done.call('items' => [], 'next' => nil, 'error' => nil) if token
          q = session.any_of.empty? ? session.query : QueryNormalizer.analyze(session.any_of.join(' '))
          groups = QueryNormalizer.online_groups(q).map { |g| g['alts'] }.reject(&:empty?)
          return done.call('items' => [], 'next' => nil, 'error' => nil) if groups.empty?
          @jobs[session.sid] = @rt.submit('catalog_text', { 'groups' => groups, 'limit' => 150, 'exclude_sources' => @disabled.call }) do |r|
            @jobs.delete(session.sid)
            items = r['ok'] ? Array(r['result']['items']) : []
            items.each { |i| i['rel'] = 0.6; CatalogProvider.inline_thumb(i) }
            done.call('items' => items, 'next' => nil, 'error' => r['ok'] ? nil : nil)
          end
        end

        # Ảnh bài Facebook có hạn dùng → hiển thị bản thu nhỏ đã lưu trên máy (data URI, không cần file://).
        def self.inline_thumb(it)
          p = it['thumb_local'].to_s
          return it if p.empty?
          if File.file?(p) && File.size(p) < 300_000
            uri = "data:image/jpeg;base64,#{[File.binread(p)].pack('m0')}"
            it['thumb'] = uri
            it['thumb_large'] = uri
          end
          it.delete('thumb_local')
          it
        rescue StandardError
          it
        end

        def cancel(session)
          @rt.cancel(@jobs.delete(session.sid))
        end

        def status_info(_settings)
          { 'id' => id, 'name' => label, 'enabled' => true, 'integrated' => true, 'note' => 'Model đã trích xuất từ các nguồn.' }
        end
      end
    end
  end
end
