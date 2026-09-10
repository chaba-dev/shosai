Pod::Spec.new do |spec|
  spec.name = 'shosai_flutter_bridge'
  spec.version = '0.0.1'
  spec.summary = 'Rust bridge for the Shōsai Flutter frontend.'
  spec.homepage = 'https://github.com/chaba2/shosai'
  spec.license = { :file => '../../../LICENSE' }
  spec.author = { 'Shōsai contributors' => 'opensource@shosai.dev' }
  spec.source = { :path => '.' }
  spec.source_files = 'Classes/**/*'
  spec.dependency 'Flutter'
  spec.platform = :ios, '13.0'
  spec.swift_version = '5.0'
  spec.frameworks = 'CoreGraphics'

  spec.script_phase = {
    :name => 'Build Rust library',
    :script => 'sh "$PODS_TARGET_SRCROOT/build.sh"',
    :execution_position => :before_compile,
    :output_files => ['${BUILT_PRODUCTS_DIR}/libshosai_flutter_bridge.a'],
    :always_out_of_date => '1',
  }
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libshosai_flutter_bridge.a -lc++ -lz',
  }
end
