#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint sherpa_onnx_ios.podspec` to validate before publishing.
#
# See also
# https://github.com/google/webcrypto.dart/blob/2010361a106d7a872d90e3dfebfed250e2ede609/ios/webcrypto.podspec#L23-L28
# https://groups.google.com/g/dart-ffi/c/nUATMBy7r0c
Pod::Spec.new do |s|
  s.name             = 'sherpa_onnx_ios'
  s.version          = '1.13.4'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Fangjun Kuang' => 'csukuangfj@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  # Patched sherpa (external-tokens API). OpenJTalk is optional: rebuild it with
  # setup.sh / ja_openjtalk/build_ios.sh when the Japanese voice is needed.
  # Without it, VAD + Whisper + non-ja TTS still link; only ja reading FFI fails.
  frameworks = ['sherpa_onnx.xcframework']
  if File.directory?(File.join(__dir__, 'ja_openjtalk.xcframework'))
    frameworks << 'ja_openjtalk.xcframework'
  end
  s.preserve_paths = frameworks.map { |f| "#{f}/**/*" }
  s.vendored_frameworks = frameworks

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
    }
  s.swift_version = '5.0'
end
