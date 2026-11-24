# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    module Providers
      # Thư viện SKP trên máy tính (chỉ mục trong bộ nhớ). Trả kết quả ngay (đồng bộ).
      class LocalProvider < BaseProvider
        PAGE = 120

        def initialize(index)
          super('local', 'Máy tính')
          @index = index
        end

        def search(session, token, &done)
          page = token.to_i
          tab = { 'favorites' => 'favorites', 'history' => 'history' }[session.kind] || 'offline'
          st = session.settings
          res = @index.search(query: session.any_of.empty? ? session.query.raw : '', any_of: session.any_of, tab: tab,
                              favorites: st['favorites'], history: st['history'], must_any: session.cat_terms,
                              size_max_mb: 0, sort: 'relevance', page: page, per_page: PAGE, with_score: true)
          maxs = max_score(session)
          items = res['items'].map do |x|
            {
              'source' => 'local', 'source_label' => 'Máy tính', 'id' => x['id'], 'title' => x['name'], 'path' => x['path'],
              'folder' => x['folder'], 'size' => x['size'], 'mtime' => x['mtime'], 'insertable' => true, 'downloadable' => true,
              'free' => true, 'format' => 'skp',
              'rel' => maxs.zero? ? 0.5 : [x['score'].to_f / maxs, 1.0].min,
              'hist_rank' => tab == 'history' ? st['history'].index(x['id']) : nil
            }
          end
          nxt = page + 1 < res['pages'] ? page + 1 : nil
          done.call('items' => items, 'next' => nxt, 'error' => nil, 'total' => res['total'])
        end

        def max_score(session)
          g = session.any_of.empty? ? session.query.groups.size : 2
          g.zero? ? 0 : 18 + 12 * (g - 1)
        end

        def status_info(settings)
          super.merge('note' => "#{settings.roots.size} thư mục · tìm tức thì trong chỉ mục trên máy.")
        end
      end
    end
  end
end
