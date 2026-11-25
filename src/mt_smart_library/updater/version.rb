# frozen_string_literal: true
# MT SMART LIBRARY PRO — nguồn DUY NHẤT về phiên bản và mã định danh plugin.
# Loader, main, giao diện, gói cập nhật và manifest đều đọc từ file này.
module MTDesign
  module SmartLibrary
    PLUGIN_ID = 'mtdesign.smart_library_pro' unless const_defined?(:PLUGIN_ID)
    PRODUCT_NAME = 'MT SMART LIBRARY PRO' unless const_defined?(:PRODUCT_NAME)
    VERSION = '1.0.13' unless const_defined?(:VERSION)
    BUILD_DATE = '2026-11-25' unless const_defined?(:BUILD_DATE)
    MIN_SKETCHUP = 22 unless const_defined?(:MIN_SKETCHUP) # SketchUp 2022
    MIN_RUBY = '2.7.0' unless const_defined?(:MIN_RUBY)

    # So sánh phiên bản dạng MAJOR.MINOR.PATCH[-tag].
    module VersionUtil
      PATTERN = /\A\d+(\.\d+){1,3}(-[0-9A-Za-z.]+)?\z/.freeze

      module_function

      def valid?(v)
        v.to_s =~ PATTERN ? true : false
      end

      def parts(v)
        main, tag = v.to_s.split('-', 2)
        nums = main.split('.').map(&:to_i)
        nums << 0 while nums.size < 4
        [nums, tag]
      end

      # -1 / 0 / 1. Bản có tag (beta) nhỏ hơn bản chính thức cùng số.
      def compare(a, b)
        na, ta = parts(a)
        nb, tb = parts(b)
        c = na <=> nb
        return c unless c.zero?
        return 0 if ta == tb
        return 1 if ta.nil?
        return -1 if tb.nil?
        ta <=> tb
      end

      def newer?(a, b)
        compare(a, b) > 0
      end
    end
  end
end
