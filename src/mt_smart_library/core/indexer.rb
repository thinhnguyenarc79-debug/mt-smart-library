# frozen_string_literal: true
require 'json'

module MTDesign
  module SmartLibrary
    # Quét thư viện trong luồng nền — CHỈ dùng Ruby filesystem, không gọi SketchUp API.
    # Cache: mỗi thư mục lưu mtime + danh sách file .skp (tên, size, mtime) + thư mục con.
    # Quét nhanh: thư mục có mtime không đổi thì dùng lại danh sách cache (không liệt kê lại).
    class Indexer
      CACHE_SCHEMA = 2
      SKIP_DIRS = ['$recycle.bin', 'system volume information', '.git', '.svn', 'node_modules', '__macosx'].freeze
      MAX_DEPTH = 64

      Result = Struct.new(:generation, :status, :entries, :errors, :stats, :dirs, :roots_state)

      def initialize(cache_path, logger = nil)
        @cache_path = cache_path
        @logger = logger
        @mutex = Mutex.new
        @dirs = {}
        @thread = nil
        @cancel = false
        @pending = nil
        @generation = 0
        @progress = idle_progress
        @results = []
        @cache_info = nil
      end

      attr_reader :cache_info

      def running?
        @thread && @thread.alive? ? true : false
      end

      def thread
        @thread
      end

      def progress
        @mutex.synchronize { @progress.dup }
      end

      # Nạp cache (gọi trong luồng nền khi mở plugin). Trả mảng Entry.
      def load_cache(roots)
        data = Util.read_json(@cache_path)
        unless data.is_a?(Hash) && data['schema'] == CACHE_SCHEMA && data['dirs'].is_a?(Hash)
          @cache_info = data.nil? ? 'Chưa có chỉ mục.' : 'Chỉ mục cũ/khác schema — sẽ quét lại.'
          return []
        end
        dirs = {}
        data['dirs'].each do |dir, v|
          next unless v.is_a?(Hash) && v['f'].is_a?(Array) && v['d'].is_a?(Array)
          dirs[Util.utf8(dir)] = { 'm' => v['m'].to_i,
                                   'f' => v['f'].select { |x| x.is_a?(Array) && x.size == 3 && x[0].is_a?(String) },
                                   'd' => v['d'].select { |x| x.is_a?(String) } }
        end
        @mutex.synchronize { @dirs = dirs }
        @cache_info = "Đã nạp chỉ mục lưu lúc #{data['saved_at']}."
        entries_from(dirs, roots)
      rescue StandardError => e
        @logger&.error('Chỉ mục hỏng, sẽ quét lại', e)
        begin
          File.rename(@cache_path, @cache_path + '.corrupt') if File.exist?(@cache_path)
        rescue StandardError
          nil
        end
        @cache_info = 'Chỉ mục bị hỏng — đã tách riêng và sẽ quét lại.'
        []
      end

      def entries_from(dirs, roots)
        out = []
        roots.each do |root|
          dirs.each do |dir, v|
            next unless Util.under_root?(dir, root)
            v['f'].each do |name, size, mtime|
              out << SearchIndex.build_entry(File.join(dir, name), size, mtime, root)
            end
          end
        end
        uniq = {}
        out.each { |e| uniq[e.id] ||= e }
        uniq.values
      end

      # Bắt đầu quét; nếu đang quét thì hủy và quét lại với roots mới.
      def start(roots, full: false)
        roots = roots.map { |r| Util.norm_path(r) }
        if running?
          @pending = { roots: roots, full: full }
          @cancel = true
          return :restarting
        end
        launch(roots, full)
        :started
      end

      def cancel
        @pending = nil
        @cancel = true if running?
      end

      # Gọi ở main thread (timer). Trả Result khi có kết quả mới.
      def poll
        res = @mutex.synchronize { @results.shift }
        if !running? && @pending
          p = @pending
          @pending = nil
          launch(p[:roots], p[:full])
        end
        res
      end

      def save_cache(dirs)
        payload = { 'schema' => CACHE_SCHEMA, 'version' => VERSION, 'saved_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'), 'dirs' => dirs }
        Util.atomic_write(@cache_path, JSON.generate(payload))
      end

      private

      def idle_progress
        { 'running' => false, 'dirs' => 0, 'files' => 0, 'errors' => 0, 'current' => '', 'started' => nil }
      end

      def launch(roots, full)
        @cancel = false
        @generation += 1
        gen = @generation
        old_dirs = @mutex.synchronize { @dirs }
        @mutex.synchronize { @progress = idle_progress.merge('running' => true, 'started' => Time.now.to_f, 'full' => full) }
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          begin
            res = walk_all(gen, roots, old_dirs, full)
            if res.status == :done
              begin
                save_cache(res.dirs)
              rescue StandardError => e
                res.errors << [@cache_path, "Không ghi được chỉ mục: #{e.message}"]
                @logger&.error('Không ghi được chỉ mục', e)
              end
            end
            @mutex.synchronize do
              @dirs = res.dirs if res.status == :done
              @results << res
            end
          rescue Exception => e # rubocop:disable Lint/RescueException
            @logger&.error('Luồng quét lỗi', e)
            @mutex.synchronize { @results << Result.new(gen, :failed, nil, [[nil, "#{e.class}: #{e.message}"]], {}, nil, {}) }
          ensure
            @mutex.synchronize { @progress['running'] = false }
          end
        end
      end

      def walk_all(gen, roots, old_dirs, full)
        new_dirs = {}
        errors = []
        roots_state = {}
        t0 = Time.now
        stats = { 'dirs' => 0, 'files' => 0, 'listed' => 0, 'reused' => 0 }
        roots.each do |root|
          break if @cancel
          unless File.directory?(root)
            roots_state[root] = 'offline'
            errors << [root, 'Không truy cập được thư mục gốc (ổ mạng/ổ ngoài chưa kết nối?). Giữ dữ liệu cũ.']
            old_dirs.each { |d, v| new_dirs[d] = v if Util.under_root?(d, root) }
            next
          end
          roots_state[root] = 'ok'
          visited = {}
          stack = [[root, 0]]
          until stack.empty?
            break if @cancel
            dir, depth = stack.pop
            k = Util.path_key(dir)
            next if visited[k]
            visited[k] = true
            node = scan_dir(dir, old_dirs[dir], full, errors, stats)
            next unless node
            new_dirs[dir] = node
            stats['dirs'] += 1
            stats['files'] += node['f'].size
            set_progress(stats, errors, dir)
            next if depth >= MAX_DEPTH
            node['d'].reverse_each { |sub| stack << [File.join(dir, sub), depth + 1] }
          end
        end
        if @cancel
          return Result.new(gen, :cancelled, nil, errors, stats, nil, roots_state)
        end
        entries = entries_from(new_dirs, roots)
        stats['seconds'] = (Time.now - t0).round(2)
        stats['models'] = entries.size
        Result.new(gen, :done, entries, errors, stats, new_dirs, roots_state)
      end

      def scan_dir(dir, cached, full, errors, stats)
        st = File.stat(dir)
        m = st.mtime.to_i
        if !full && cached && cached['m'] == m
          stats['reused'] += 1
          return cached
        end
        files = []
        subs = []
        Dir.children(dir, encoding: Encoding::UTF_8).each do |name|
          next if name.start_with?('.') || name.start_with?('~$')
          unless name.valid_encoding?
            errors << [File.join(dir, name.scrub('?')), 'Tên file không hợp lệ UTF-8 — bỏ qua.']
            next
          end
          full_path = File.join(dir, name)
          begin
            ls = File.lstat(full_path)
            next if ls.symlink?
            if ls.directory?
              subs << name unless SKIP_DIRS.include?(name.downcase)
            elsif ls.file? && name =~ /\.skp\z/i
              files << [name, ls.size, ls.mtime.to_i]
            end
          rescue SystemCallError, IOError => e
            errors << [full_path, e.message]
          end
        end
        stats['listed'] += 1
        { 'm' => m, 'f' => files, 'd' => subs.sort }
      rescue SystemCallError, IOError => e
        errors << [dir, e.message]
        nil
      end

      def set_progress(stats, errors, dir)
        @mutex.synchronize do
          @progress['dirs'] = stats['dirs']
          @progress['files'] = stats['files']
          @progress['errors'] = errors.size
          @progress['current'] = dir
        end
      end
    end
  end
end
