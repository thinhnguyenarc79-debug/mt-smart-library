# frozen_string_literal: true
require 'json'
require 'fileutils'

module MTDesign
  module SmartLibrary
    module Providers
      # Poly Haven: tải danh mục model 1 lần (≈0,5 MB, lưu đĩa 24 giờ) qua API chính thức,
      # sau đó tìm ngay trên máy theo tên/tag/danh mục (Việt → Anh qua QueryNormalizer).
      class PolyHavenProvider < BaseProvider
        TTL = 24 * 3600
        PAGE = 24

        def initialize(http, data_root, logger = nil)
          super('polyhaven', 'Poly Haven')
          @http = http
          @file = File.join(data_root, 'cache', 'polyhaven_models.json')
          @log = logger
          @catalog = nil
          @loaded_at = 0
          @waiting = []
          @job = nil
        end

        def online?
          true
        end

        def enabled?(settings)
          settings['sources']['polyhaven'] != false
        end

        def applicable?(session, settings)
          return false unless enabled?(settings)
          return false if %w[history local favorites].include?(session.kind)
          !session.online_q.to_s.strip.empty?
        end

        def search(session, token, &done)
          with_catalog do |list, err|
            next done.call('items' => [], 'next' => nil, 'error' => err, 'offline' => true) unless list
            matched = list.map { |a| normalize(a) }
                          .select { |it| ResultRanker.relevant_online?(it, session.oquery, session.cat_terms) }
                          .sort_by { |it| -it['likes'].to_i }
            off = token.to_i
            page = matched[off, PAGE] || []
            nxt = off + PAGE < matched.size ? off + PAGE : nil
            done.call('items' => page, 'next' => nxt, 'error' => nil, 'total' => matched.size)
          end
        end

        def cancel(_session); end

        def find(id)
          (@catalog || []).find { |a| a['id'] == id }
        end

        def normalize(a)
          {
            'source' => 'polyhaven', 'source_label' => 'Poly Haven', 'uid' => "ph-#{a['id']}", 'ph_id' => a['id'],
            'title' => a['name'], 'thumb' => a['thumb'], 'thumb_large' => a['thumb'],
            'author' => a['authors'].join(', '), 'license' => 'CC0 (miễn phí, dùng cả thương mại)',
            'url' => PolyHaven.page_url(a['id']), 'downloadable' => true, 'free' => true, 'insertable' => true,
            'format' => 'gltf', 'formats' => [{ 'type' => 'gltf' }],
            'tags' => a['tags'] + a['categories'] + a['category'].split('/'), 'cats' => [],
            'likes' => a['downloads'], 'faces' => a['polycount']
          }
        end

        def status_info(settings)
          super.merge('note' => 'Tích hợp qua Poly Haven API chính thức: model CC0 chất lượng cao (nội thất, trang trí, kiến trúc), ' \
                                'không cần tài khoản. Bấm CHÈN là tải glTF + texture và chèn thẳng.')
        end

        private

        # Gọi khối với (danh_sách, lỗi). Dùng bản trên đĩa nếu còn hạn; mạng lỗi thì dùng bản cũ nếu có.
        def with_catalog(&blk)
          return blk.call(@catalog, nil) if @catalog && Time.now.to_f - @loaded_at < TTL
          disk = read_disk
          if disk && Time.now.to_f - disk[0] < TTL
            @catalog, @loaded_at = disk[1], disk[0]
            return blk.call(@catalog, nil)
          end
          @waiting << blk
          return if @job
          @job = @http.request(url: PolyHaven::CATALOG_URL, headers: { 'Accept' => 'application/json' }, timeout: 30) do |res|
            @job = nil
            err = nil
            if res.ok
              begin
                @catalog = PolyHaven.parse_catalog(res.body)
                @loaded_at = Time.now.to_f
                write_disk(@catalog)
              rescue StandardError => e
                err = "Dữ liệu Poly Haven không đọc được: #{e.message}"
              end
            else
              err = res.code > 0 ? "Poly Haven trả lỗi HTTP #{res.code}." : HttpClient.friendly(res)
            end
            if err && disk
              @catalog, @loaded_at = disk[1], disk[0] # dùng bản cũ, vẫn tìm được khi mất mạng
              err = nil
            end
            cbs = @waiting
            @waiting = []
            cbs.each { |cb| cb.call(err ? nil : @catalog, err) }
          end
        end

        def read_disk
          return nil unless File.file?(@file)
          d = JSON.parse(File.read(@file, encoding: 'UTF-8'))
          return nil unless d.is_a?(Hash) && d['items'].is_a?(Array)
          [d['saved_at'].to_f, d['items']]
        rescue StandardError => e
          @log&.warn("Bỏ qua cache Poly Haven hỏng: #{e.message}")
          nil
        end

        def write_disk(list)
          FileUtils.mkdir_p(File.dirname(@file))
          Util.atomic_write(@file, JSON.generate('saved_at' => Time.now.to_f, 'items' => list))
        rescue StandardError => e
          @log&.warn("Không ghi được cache Poly Haven: #{e.message}")
        end
      end
    end
  end
end
