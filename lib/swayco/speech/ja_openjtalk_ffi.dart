/// Dart FFI binding to the native OpenJTalk reading frontend
/// (`native/ja_openjtalk/src/ja_frontend.c`): UTF-8 Japanese → katakana reading,
/// equivalent to `pyopenjtalk.g2p(text, kana=True)`.
///
/// This is the native half of the ja frontend; feed its output through
/// [expandChoonpu] + [phonemizeKatakana] (ja_phonemizer.dart) to get the model's
/// token/tone tensors. One [JaOpenJTalk] is single-threaded — create one per
/// isolate (the TTS worker owns its own, like sherpa's OfflineTts).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _Create = Pointer<Void> Function(Pointer<Utf8>);
typedef _KanaNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _Kana = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _Destroy = void Function(Pointer<Void>);

class JaOpenJTalk {
  JaOpenJTalk._(this._handle, this._kana, this._free, this._destroy);

  final Pointer<Void> _handle;
  final _Kana _kana;
  final _Free _free;
  final _Destroy _destroy;
  bool _disposed = false;

  /// Open the native library. On device it is linked into the app process
  /// (iOS/macOS static framework), so [DynamicLibrary.process] resolves the
  /// symbols; on desktop dev pass an explicit [libraryPath] to the built dylib.
  static DynamicLibrary _open([String? libraryPath]) {
    if (libraryPath != null) return DynamicLibrary.open(libraryPath);
    if (Platform.isIOS || Platform.isMacOS) {
      // Symbols are available in the process when the framework is linked.
      try {
        return DynamicLibrary.process();
      } catch (_) {
        return DynamicLibrary.open('libja_openjtalk.dylib');
      }
    }
    if (Platform.isAndroid) return DynamicLibrary.open('libja_openjtalk.so');
    return DynamicLibrary.open('libja_openjtalk.dylib');
  }

  /// Load [dictDir] (the extracted `open_jtalk_dic_utf_8-1.11`). Throws if the
  /// dictionary can't be loaded.
  factory JaOpenJTalk.load(String dictDir, {String? libraryPath}) {
    final lib = _open(libraryPath);
    final create =
        lib.lookupFunction<_CreateNative, _Create>('ja_frontend_create');
    final kana = lib.lookupFunction<_KanaNative, _Kana>('ja_frontend_kana');
    final free = lib.lookupFunction<_FreeNative, _Free>('ja_frontend_free');
    final destroy =
        lib.lookupFunction<_DestroyNative, _Destroy>('ja_frontend_destroy');

    final dirPtr = dictDir.toNativeUtf8();
    final handle = create(dirPtr);
    malloc.free(dirPtr);
    if (handle == nullptr) {
      throw StateError('ja_frontend_create failed for dict "$dictDir"');
    }
    return JaOpenJTalk._(handle, kana, free, destroy);
  }

  /// Katakana reading of [text] (e.g. "今日は元気ですか" → "キョーワゲンキデスカ").
  String kana(String text) {
    if (_disposed) throw StateError('JaOpenJTalk used after dispose');
    final inPtr = text.toNativeUtf8();
    final outPtr = _kana(_handle, inPtr);
    malloc.free(inPtr);
    if (outPtr == nullptr) return '';
    try {
      return outPtr.toDartString();
    } finally {
      _free(outPtr);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroy(_handle);
  }
}
