# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Cache kết quả theo (nguồn, truy vấn, danh mục, trang) — LRU + TTL, chỉ trong bộ nhớ phiên.
    class ResultCache
      def initialize(max: 80, ttl: 600)
        @max = max
        @ttl = ttl
        @h = {}
      end

      def get(key)
        e = @h.delete(key)
        return nil unless e
        return nil if Time.now.to_f - e[0] > @ttl
        @h[key] = e
        e[1]
      end

      def put(key, value)
        @h.delete(key)
        @h[key] = [Time.now.to_f, value]
        @h.shift while @h.size > @max
        value
      end

      def clear
        @h.clear
      end

      def size
        @h.size
      end
    end
  end
end
