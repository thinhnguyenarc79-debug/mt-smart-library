# frozen_string_literal: true
require 'json'
require 'base64'

module MTDesign
  module SmartLibrary
    # AI gợi ý TỪ KHÓA từ ảnh (OpenAI Chat Completions + vision + structured outputs).
    # Đây KHÔNG phải tìm kiếm ảnh tương đồng (không dùng embedding ảnh).
    module Vision
      MAX_IMAGE_BYTES = 8 * 1024 * 1024
      FIELDS = %w[object_type style material color queries_vi queries_en].freeze
      SCHEMA = {
        'type' => 'object',
        'additionalProperties' => false,
        'required' => FIELDS,
        'properties' => {
          'object_type' => { 'type' => 'string', 'description' => 'Main object type in English, e.g. "sofa", "pendant lamp"' },
          'style' => { 'type' => 'string', 'description' => 'Design style, e.g. modern, scandinavian, indochine' },
          'material' => { 'type' => 'string', 'description' => 'Main visible materials' },
          'color' => { 'type' => 'string', 'description' => 'Main colors' },
          'queries_vi' => { 'type' => 'array', 'items' => { 'type' => 'string' }, 'description' => '3-5 Vietnamese search phrases' },
          'queries_en' => { 'type' => 'array', 'items' => { 'type' => 'string' }, 'description' => '3-5 English search phrases' }
        }
      }.freeze
      PROMPT = <<~TXT
        You help an interior/architecture designer find a matching SketchUp 3D model.
        Look at the image, identify the single main furniture / fixture / architectural object.
        Return JSON with: object_type (English noun phrase), style, material, color,
        queries_vi: 3-5 short Vietnamese search phrases WITH proper diacritics (2-5 words each, e.g. "ghế sofa vải xám"),
        queries_en: 3-5 short English search phrases (2-6 words each) suitable for 3D model libraries.
        No brand names unless clearly visible. JSON only.
      TXT

      module_function

      def mime_of(bytes)
        b = bytes.byteslice(0, 16).to_s.b
        return 'image/png' if b.start_with?("\x89PNG".b)
        return 'image/jpeg' if b.start_with?("\xFF\xD8\xFF".b)
        return 'image/webp' if b.start_with?('RIFF'.b) && b.byteslice(8, 4) == 'WEBP'.b
        return 'image/gif' if b.start_with?('GIF8'.b)
        nil
      end

      def reasoning_model?(model)
        model.to_s =~ /\A(o\d|gpt-5|gpt-6)/ ? true : false
      end

      # variant: :full, :no_reasoning, :json_object, :max_tokens (các phương án dự phòng)
      def build_body(model:, mime:, b64:, detail: 'low', variant: [])
        variant = Array(variant)
        body = {
          'model' => model,
          'messages' => [
            { 'role' => 'system', 'content' => PROMPT },
            { 'role' => 'user', 'content' => [
              { 'type' => 'text', 'text' => 'Analyze this image and return the JSON.' },
              { 'type' => 'image_url', 'image_url' => { 'url' => "data:#{mime};base64,#{b64}", 'detail' => detail } }
            ] }
          ]
        }
        body['response_format'] = if variant.include?(:json_object)
                                    { 'type' => 'json_object' }
                                  else
                                    { 'type' => 'json_schema', 'json_schema' => { 'name' => 'sketchup_model_keywords', 'strict' => true, 'schema' => SCHEMA } }
                                  end
        if variant.include?(:max_tokens)
          body['max_tokens'] = 800
        else
          body['max_completion_tokens'] = reasoning_model?(model) ? 4000 : 800
        end
        body['reasoning_effort'] = 'low' if reasoning_model?(model) && !variant.include?(:no_reasoning)
        JSON.generate(body)
      end

      def headers(key)
        { 'Authorization' => "Bearer #{key}", 'Content-Type' => 'application/json' }
      end

      # Phương án thử lại khi API báo tham số không hỗ trợ (HTTP 400).
      def fallback_variant(code, body, current)
        return nil unless code == 400
        msg = error_text(body).downcase
        cur = Array(current)
        return cur + [:no_reasoning] if msg.include?('reasoning') && !cur.include?(:no_reasoning)
        return cur + [:json_object] if (msg.include?('json_schema') || msg.include?('response_format')) && !cur.include?(:json_object)
        return cur + [:max_tokens] if msg.include?('max_completion_tokens') && !cur.include?(:max_tokens)
        nil
      end

      def error_text(body)
        j = JSON.parse(body.to_s)
        e = j.is_a?(Hash) ? j['error'] : nil
        e.is_a?(Hash) ? "#{e['code']} #{e['type']} #{e['message']}" : body.to_s[0, 300]
      rescue StandardError
        body.to_s[0, 300]
      end

      def error_message(code, body)
        t = error_text(body)
        case code
        when 401 then 'API key không hợp lệ hoặc đã bị thu hồi (401). Kiểm tra lại key trong Cài đặt.'
        when 403 then "Key/dự án không có quyền dùng model này (403). #{t[0, 160]}"
        when 404 then "Model không tồn tại hoặc tài khoản không có quyền (404). Đổi model trong Cài đặt. #{t[0, 120]}"
        when 429
          if t.include?('insufficient_quota')
            'Hết hạn mức/credit OpenAI (429 insufficient_quota). Nạp thêm tại platform.openai.com > Billing.'
          else
            'Gửi quá nhiều yêu cầu (429 rate limit). Đợi khoảng 20–60 giây rồi thử lại.'
          end
        when 400 then "Yêu cầu không hợp lệ (400) — model có thể không hỗ trợ ảnh: #{t[0, 200]}"
        when 500..599 then "Máy chủ OpenAI lỗi tạm thời (#{code}). Thử lại sau."
        else "OpenAI trả lỗi HTTP #{code}: #{t[0, 200]}"
        end
      end

      def clean_str(v, max = 80)
        Util.utf8(v).gsub(/[\r\n\t]+/, ' ').strip[0, max]
      end

      # Trả Hash đã kiểm tra; raise nếu sai định dạng.
      def parse_result(body)
        data = JSON.parse(body.to_s)
        choice = data.dig('choices', 0, 'message') || {}
        if choice['refusal'].to_s.strip != ''
          raise "AI từ chối phân tích ảnh: #{clean_str(choice['refusal'], 200)}"
        end
        content = choice['content']
        content = content.map { |c| c.is_a?(Hash) ? c['text'].to_s : c.to_s }.join if content.is_a?(Array)
        content = content.to_s.strip
        raise 'AI không trả nội dung.' if content.empty?
        content = content.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/, '')
        obj = JSON.parse(content)
        raise 'AI trả JSON sai cấu trúc.' unless obj.is_a?(Hash)
        out = {}
        %w[object_type style material color].each { |k| out[k] = clean_str(obj[k], 120) }
        %w[queries_vi queries_en].each do |k|
          out[k] = Array(obj[k]).map { |q| clean_str(q, 80) }.reject(&:empty?).uniq.first(6)
        end
        if out['queries_vi'].empty? && out['queries_en'].empty?
          raise 'AI không đưa ra được từ khóa tìm kiếm.' if out['object_type'].empty?
          out['queries_en'] = [out['object_type']]
        end
        out['usage'] = data['usage'].is_a?(Hash) ? data['usage'].select { |k, _| %w[prompt_tokens completion_tokens total_tokens].include?(k) } : {}
        out
      rescue JSON::ParserError
        raise 'Không đọc được JSON từ AI (phản hồi không phải JSON hợp lệ).'
      end
    end
  end
end
