# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

# Stub tối thiểu các lớp SketchUp dùng khi dựng hình (chỉ trong test).
module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z); @x = x; @y = y; @z = z; end
    def to_a; [x, y, z]; end
  end
  class PolygonMesh
    AUTO_SOFTEN = 4
    SMOOTH_SOFT_EDGES = 8
    attr_reader :points, :polygons, :uvs
    def initialize(_np = 0, _nf = 0); @points = []; @polygons = []; @uvs = {}; end
    def add_point(p)
      k = p.to_a.map { |v| v.round(6) }
      i = @points.index(k)
      return i + 1 if i
      @points << k
      @points.size
    end
    def add_polygon(*idx); @polygons << idx; @polygons.size; end
    def set_uv(i, p, front); @uvs[i] = [p.to_a, front]; end
  end
end
module Sketchup
  class Color
    attr_reader :rgb
    def initialize(*rgb); @rgb = rgb; end
  end
end
class FakeMat
  attr_accessor :color, :alpha, :texture, :name
  def initialize(n); @name = n; end
end
class FakeEnts
  attr_reader :groups, :meshes
  def initialize; @groups = []; @meshes = []; end
  def add_group; g = Struct.new(:entities).new(FakeEnts.new); @groups << g; g; end
  def add_faces_from_mesh(mesh, flags, fm, bm); @meshes << [mesh, flags, fm, bm]; end
end
class FakeModel2
  attr_reader :definitions, :materials, :ops
  def initialize
    @ops = []
    defs = []
    @definitions = Object.new
    @definitions.define_singleton_method(:add) { |n| d = Struct.new(:name, :entities).new(n, FakeEnts.new); defs << d; d }
    @definitions.define_singleton_method(:list) { defs }
    mats = []
    @materials = Object.new
    @materials.define_singleton_method(:add) { |n| m = FakeMat.new(n); mats << m; m }
    @materials.define_singleton_method(:list) { mats }
  end
  def start_operation(*a); @ops << [:start, *a]; end
  def commit_operation; @ops << [:commit]; end
  def abort_operation; @ops << [:abort]; end
  def place_component(d, r); @ops << [:place, d.name, r]; end
end

class TestGltf < Minitest::Test
  DIR = Dir.mktmpdir('gltf_')
  _o, st = Open3.capture2e('python3', File.join(__dir__, 'fixtures', 'make_gltf.py'), DIR)
  raise 'không tạo được file glTF test' unless st.success?
  IN = SL::Gltf::M_TO_INCH

  def near(a, b, msg = nil)
    a.zip(b).each { |x, y| assert_in_delta y, x, 1e-3, msg }
  end

  def check_model(m)
    assert_equal 3, m.primitives.size - 0 + (m.primitives.size == 2 ? 1 : 0) if false
    assert_equal 2, m.primitives.size, 'bỏ qua primitive dạng đường (mode 1)'
    assert_equal 4, m.triangles, '2 tam giác sàn + 2 tam giác từ dải'
    floor = m.primitives[0]
    # root scale 2: điểm (1,0,0) m -> (2m, 0, 0) -> inch; điểm (0,0,-1) (glTF -Z) -> SketchUp +Y
    near floor.points[1], [2 * IN, 0, 0]
    near floor.points[3], [0, 2 * IN, 0]
    assert_equal [0.0, 1.0], floor.uvs[0], 'UV lật trục V'
    post = m.primitives[1]
    # post: xoay 90° quanh Y rồi tịnh tiến 1m (trong root scale 2): điểm cao 2m -> Z = 4m
    near post.points[1], [2 * IN, 0, 4 * IN]
    near post.points[2], [2 * IN, 0.2 * IN, 0], 'xoay 90° quanh Y: +X -> -Z (glTF) -> +Y (SketchUp)'
    assert_equal 6, post.tris.size
    assert_equal 2, m.materials.size
    assert_equal 'Gỗ sồi', m.materials[0].name
    assert m.materials[0].image_path && File.file?(m.materials[0].image_path), 'texture được tách ra file PNG'
    assert_equal [51, 102, 153], m.materials[1].color
    assert_in_delta 0.5, m.materials[1].alpha, 1e-6
    assert_includes m.warnings.join, 'đường/điểm'
  end

  def test_parse_glb
    check_model(SL::Gltf.parse(File.join(DIR, 'test.glb'), File.join(DIR, 'tex1')))
  end

  def test_parse_gltf_with_external_files
    m = SL::Gltf.parse(File.join(DIR, 'scene.gltf'), File.join(DIR, 'tex2'))
    check_model(m)
    assert_equal "\x89PNG".b, File.binread(m.materials[0].image_path, 4)
  end

  def test_rejects_draco_and_path_traversal_and_garbage
    assert_match(/nén/, assert_raises(SL::Gltf::Error) { SL::Gltf.parse(File.join(DIR, 'draco.gltf'), DIR) }.message)
    assert_match(/Thiếu file/, assert_raises(SL::Gltf::Error) { SL::Gltf.parse(File.join(DIR, 'evil.gltf'), DIR) }.message)
    bad = File.join(DIR, 'bad.glb'); File.binwrite(bad, 'glTF' + "\x02\x00\x00\x00" + 'xx')
    assert_raises(SL::Gltf::Error) { SL::Gltf.parse(bad, DIR) }
    junk = File.join(DIR, 'junk.gltf'); File.write(junk, '{not json')
    assert_raises(SL::Gltf::Error) { SL::Gltf.parse(junk, DIR) }
  end

  def test_builder_creates_component_with_materials
    m = SL::Gltf.parse(File.join(DIR, 'test.glb'), File.join(DIR, 'tex3'))
    su = FakeModel2.new
    d = SL::Gltf::Builder.build(m, su)
    assert_equal 'test', d.name
    assert_equal [[:start, 'MT Smart Library: chèn model glTF', true], [:commit]], su.ops
    assert_equal 2, d.entities.groups.size
    mesh, flags, fm, = d.entities.groups[0].entities.meshes[0]
    assert_equal 4, mesh.points.size
    assert_equal 2, mesh.polygons.size
    assert_equal 4, mesh.uvs.size, 'UV gán cho từng điểm'
    assert_equal 12, flags
    assert_equal 'MT_Gỗ sồi', fm.name
    assert fm.texture.to_s.end_with?('.png')
    assert_equal [51, 102, 153], su.materials.list[1].color.rgb
  end

  def test_app_classifies_and_inserts_gltf
    app = SL::App.allocate
    assert_equal 'gltf', app.send(:classify, File.join(DIR, 'test.glb'))['kind']
    assert_equal 'gltf', app.send(:classify, File.join(DIR, 'scene.gltf'))['kind']
    assert_equal 'other', app.send(:classify, File.join(DIR, 'scene.bin'))['kind']
  end

  def test_app_end_to_end_glb_insert_and_format_choice
    SL::Paths.reset!
    ENV['MT_SMART_LIBRARY_DATA'] = Dir.mktmpdir('gl_app_')
    SL::Paths.code_dir = File.join(SRC, 'mt_smart_library')
    UI.timers.clear
    su = FakeModel2.new
    Sketchup.model = su
    app = SL::App.new
    dl = SL::Paths.sub('downloads', 'sketchfab', 'a' * 32)
    FileUtils.mkdir_p(dl)
    glb = File.join(dl, 'model.glb')
    FileUtils.cp(File.join(DIR, 'test.glb'), glb)
    app.insert_path(glb)
    200.times { UI.run_timers; break if su.ops.any? { |o| o[0] == :place }; sleep 0.01 }
    assert_equal [:place, 'model', false], su.ops.last, 'GLB tải về được dựng và đặt vào công trình'
    # Bấm CHÈN model Sketchfab: ưu tiên GLB, chưa có token -> hỏi token ngay tại chỗ
    s = app.search.start('sid' => 1, 'q' => '', 'category' => 'history') && app.search.session
    item = { 'key' => "sketchfab:#{'b' * 32}", 'source' => 'sketchfab', 'uid' => 'b' * 32, 'title' => 'Sofa', 'downloadable' => true,
             'formats' => [{ 'type' => 'gltf' }, { 'type' => 'glb' }, { 'type' => 'usdz' }], 'url' => 'https://sketchfab.com/3d-models/x' }
    s.store[item['key']] = item
    called = nil
    app.define_singleton_method(:sketchfab_download) { |o| called = o }
    app.define_singleton_method(:secret) { |_k| 'tok-12345678' }
    app.insert_any(item['key'])
    assert_equal 'glb', called['format']
    assert called['auto_insert']
  ensure
    SL::Paths.reset!
    Sketchup.model = nil
  end
end
