# frozen_string_literal: true
require_relative 'test_helper'

# V1.0.14 TEAM EDITION (ChatGPT) — giữ nguyên ở V1.0.15: xuất/nhập cấu hình công ty không mang bí mật.
class TestTeamConfig < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('team_')
    @st = SL::Settings.new(File.join(@dir, 'settings.json'))
    @reg = SL::SourceRegistry.new(File.join(@dir, 'sources.json'), builtins: [])
  end

  def test_export_has_no_secrets_and_keeps_official_channel
    @reg.add('url' => 'https://www.facebook.com/groups/vietnamsketchup', 'type' => '')
    @reg.add('url' => 'https://user:pass@site.example.com/a?token=1', 'type' => 'website') rescue nil
    data = SL::TeamConfig.export(@st, @reg)
    js = JSON.generate(data)
    refute_match(/pass@|token=|dpapi|api_key/i, js)
    assert_equal 'official', data['settings']['update']['source']
    assert_equal 'cpu', data['settings']['ai']['device'], 'máy nhân viên luôn CPU (tránh lỗi DirectML)'
    dir2 = Dir.mktmpdir('team2_')
    st2 = SL::Settings.new(File.join(dir2, 'settings.json'))
    reg2 = SL::SourceRegistry.new(File.join(dir2, 'sources.json'), builtins: [])
    n = SL::TeamConfig.import(JSON.parse(js), st2, reg2)
    assert_operator n, :>=, 1
    assert_equal 'official', st2['update']['source']
    assert reg2.list.any? { |s| s['url'].include?('vietnamsketchup') }
  end
end
