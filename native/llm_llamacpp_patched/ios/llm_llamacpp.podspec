#
# CocoaPods spec for llm_llamacpp on iOS.
#
# Upstream (brynjen/dart-llm) declares `ios: ffiPlugin: true` but ships NO ios/
# podspec, and its native-assets hook looks for a dynamic `llama.framework` that
# the v0.1.0 iOS release does NOT contain — that release ships STATIC archives
# (libllama.a + libggml*.a incl. libggml-metal.a). And the plugin's own iOS Dart
# path resolves symbols via `DynamicLibrary.process()` (see loader_flutter.dart
# / backend_initializer.dart), i.e. it EXPECTS the llama/ggml symbols linked
# statically into the app binary. So the correct iOS integration is to vendor
# those static libs and -force_load them — the same shape as ios/Frameworks/
# libvosk.a elsewhere in this app. The native-assets hook is patched to skip iOS
# (hook/build.dart) so it does not fight this.
#
# Nothing in Dart/Swift references the llama/ggml symbols at LINK time (they are
# looked up at runtime through process()), so without -force_load the linker
# dead-strips every object. force_load pulls all members of each archive in.
#
# Part of the native/llm_llamacpp_patched override.
#
# Built from sjl623/llama.cpp @ STQ_0 (PR #22836) by scripts/build_llama_ios.sh,
# NOT the plugin's prebuilt GitHub release — that stock llama.cpp lacks the
# STQ1_0 ternary kernel the 1.25-bit Hy-MT2 model needs. This source build emits
# 5 libs (ggml-blas folded into Accelerate; common/cpp-httplib are example-only
# C++ helpers the C-API FFI never calls, so they are not built).
llama_libs = %w[
  libllama.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a
]
# Path is resolved from the Runner (app) target's SRCROOT (= the ios/ dir), via
# the Flutter plugin symlink. $(PODS_TARGET_SRCROOT) does NOT work here: it is a
# pod-target variable, empty in the app target, so force_load would get a bogus
# absolute "/libs/..." path and Xcode fails with "Build input files cannot be
# found".
force_load = llama_libs.map { |l|
  "-force_load $(SRCROOT)/.symlinks/plugins/llm_llamacpp/ios/libs/#{l}"
}.join(' ')

# Dead-strip roots. force_load pulls the objects in, but DEAD_CODE_STRIPPING=YES
# then removes every llama_* function as unreachable — nothing references them
# at LINK time (the Dart FFI looks them up at runtime via
# DynamicLibrary.process()). Result: the code is in the binary but nm shows 0
# llama symbols and dlsym fails at first call. `-u` marks each as a root so
# dead-strip keeps it, exactly like ios/Frameworks/libvosk.a's -u _vosk_* list.
# The 233 names are the symbols llama_bindings.dart actually looks up; the ggml
# symbols they call survive transitively. Regenerate llama_symbols.txt from the
# bindings if the plugin's API surface changes.
# Emit as `-Wl,-u,_sym` (single comma-joined token), NOT `-u _sym` (two tokens):
# CocoaPods re-tokenises user_target_xcconfig OTHER_LDFLAGS and splits the pair,
# so the linker sees the bare symbol as an input FILE ("No such file or
# directory: '_llama_backend_init'"). The -Wl, form cannot be split.
sym_file = File.join(__dir__, 'llama_symbols.txt')
keep_roots = File.readlines(sym_file).map(&:strip).reject(&:empty?)
                 .map { |s| "-Wl,-u,_#{s}" }.join(' ')

Pod::Spec.new do |s|
  s.name             = 'llm_llamacpp'
  s.version          = '0.1.9'
  s.summary          = 'On-device LLM via llama.cpp (FFI, static libs + Metal).'
  s.description      = 'llama.cpp/ggml static libraries force-loaded into the app; Dart resolves symbols via DynamicLibrary.process().'
  s.homepage         = 'https://github.com/brynjen/dart-llm'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'brynjen' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # NOT vendored_libraries: that would ALSO link each archive (via -l), and
  # combined with the -force_load below every object links twice → duplicate
  # symbols. force_load alone pulls them in, exactly like ios/Frameworks/
  # libvosk.a. The libs stay in place under the plugin symlink.
  #
  # OTHER_LDFLAGS goes on the APP target (user_target_xcconfig) because the app
  # binary is what DynamicLibrary.process() reads. ggml-metal needs Metal +
  # MetalKit + Foundation; ggml-blas needs Accelerate; llama.cpp is C++.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => "#{force_load} #{keep_roots} " \
                       '-framework Metal -framework MetalKit ' \
                       '-framework Foundation -framework Accelerate -lc++',
  }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
