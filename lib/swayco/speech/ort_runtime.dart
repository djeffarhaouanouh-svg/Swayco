/// Minimal `dart:ffi` binding to the ONNX Runtime C API — **the runtime the app
/// already ships**, not a new one.
///
/// The app has exactly one ONNX Runtime (see the `sherpa_onnx` note in
/// pubspec.yaml): sherpa links it, and a second copy makes the iOS link fail on
/// duplicate symbols. The voice converter therefore does not bring its own —
/// it opens the runtime that is already in the process and drives it directly.
///
/// * macOS: sherpa's plugin vendors `libonnxruntime.1.27.0.dylib` as a separate
///   dylib which exports `OrtGetApiBase`, so this works today.
/// * iOS: sherpa's xcframework statically links the runtime and hides its
///   symbols, so [OrtRuntime.open] finds nothing until sherpa is rebuilt with
///   `SHERPA_ONNXRUNTIME_LIB_DIR` (see docs/voice-cloning.md, blocker 1).
///
/// The C API is a struct of function pointers returned by
/// `OrtGetApiBase()->GetApi(version)`. That struct is append-only across
/// releases — ORT never reorders or removes a member — so the indices below are
/// stable. They were generated from `onnxruntime_c_api.h` at tag v1.27.0.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Member indices in `struct OrtApi`.
const _kGetErrorMessage = 2;
const _kCreateEnv = 3;
const _kCreateSession = 7;
const _kRun = 9;
const _kCreateSessionOptions = 10;
const _kSetIntraOpNumThreads = 24;
const _kCreateTensorWithDataAsOrtValue = 49;
const _kGetTensorMutableData = 51;
const _kGetDimensionsCount = 61;
const _kGetDimensions = 62;
const _kGetTensorTypeAndShape = 65;
const _kCreateCpuMemoryInfo = 69;
const _kReleaseEnv = 92;
const _kReleaseStatus = 93;
const _kReleaseMemoryInfo = 94;
const _kReleaseSession = 95;
const _kReleaseValue = 96;
const _kReleaseTensorTypeAndShapeInfo = 99;
const _kReleaseSessionOptions = 100;

const _ortLoggingLevelError = 3;
const _ortDeviceAllocator = 0;
const _ortMemTypeDefault = 0;
const _ortTensorElemTypeFloat = 1;
const _ortTensorElemTypeInt64 = 7;

/// The highest C API version this binding was generated against. [OrtRuntime]
/// walks down from here so an older runtime still works — every member it uses
/// has existed since version 1.
const _ortApiVersion = 27;

typedef _Status = Pointer<Void>;

/// A loaded ONNX Runtime, plus the process-wide `OrtEnv`.
///
/// One instance per isolate: FFI symbols and the ORT env are not shared across
/// isolates, and the converter runs in the TTS worker isolate anyway.
class OrtRuntime {
  OrtRuntime._(this._api, this._env, this._memInfo);

  final Pointer<Pointer<Void>> _api;
  final Pointer<Void> _env;
  final Pointer<Void> _memInfo;
  bool _disposed = false;

  /// Open the runtime already linked into the process.
  ///
  /// [libraryPath] is for desktop dev, where nothing has loaded the dylib yet
  /// (`dart run` against the vendored `libonnxruntime.1.27.0.dylib`).
  factory OrtRuntime.open({String? libraryPath, int numThreads = 2}) {
    final lib = _openLibrary(libraryPath);
    final getApiBase = lib.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('OrtGetApiBase');
    final base = getApiBase();
    if (base == nullptr) throw StateError('OrtGetApiBase returned null');

    // struct OrtApiBase { const OrtApi*(*GetApi)(uint32_t); const char*(*GetVersionString)(void); }
    final getApi = base
        .cast<Pointer<NativeFunction<Pointer<Void> Function(Uint32)>>>()
        .value
        .asFunction<Pointer<Void> Function(int)>();

    Pointer<Void> api = nullptr;
    for (var v = _ortApiVersion; v >= 11 && api == nullptr; v--) {
      api = getApi(v);
    }
    if (api == nullptr) {
      throw StateError('ONNX Runtime too old: no C API <= $_ortApiVersion');
    }
    final table = api.cast<Pointer<Void>>();

    final envOut = calloc<Pointer<Void>>();
    final logId = 'swayco'.toNativeUtf8();
    try {
      _check(
        table,
        table[_kCreateEnv]
            .cast<
                NativeFunction<
                    _Status Function(Int32, Pointer<Utf8>,
                        Pointer<Pointer<Void>>)>>()
            .asFunction<
                _Status Function(int, Pointer<Utf8>,
                    Pointer<Pointer<Void>>)>()(
          _ortLoggingLevelError,
          logId,
          envOut,
        ),
      );
      final memOut = calloc<Pointer<Void>>();
      try {
        _check(
          table,
          table[_kCreateCpuMemoryInfo]
              .cast<
                  NativeFunction<
                      _Status Function(Int32, Int32, Pointer<Pointer<Void>>)>>()
              .asFunction<
                  _Status Function(int, int, Pointer<Pointer<Void>>)>()(
            _ortDeviceAllocator,
            _ortMemTypeDefault,
            memOut,
          ),
        );
        return OrtRuntime._(table, envOut.value, memOut.value);
      } finally {
        calloc.free(memOut);
      }
    } finally {
      calloc.free(logId);
      calloc.free(envOut);
    }
  }

  static DynamicLibrary _openLibrary(String? path) {
    if (path != null) return DynamicLibrary.open(path);
    // On device the runtime is already loaded (sherpa pulled it in), so its
    // symbols are in the process. Named opens are the desktop-dev fallback.
    try {
      final p = DynamicLibrary.process();
      p.lookup('OrtGetApiBase');
      return p;
    } catch (_) {}
    final names = Platform.isAndroid
        ? const ['libonnxruntime.so']
        : const [
            'libonnxruntime.1.27.0.dylib',
            'libonnxruntime.dylib',
            'onnxruntime.framework/onnxruntime',
          ];
    for (final n in names) {
      try {
        return DynamicLibrary.open(n);
      } catch (_) {}
    }
    throw StateError(
      'no ONNX Runtime in this process — on iOS sherpa must be rebuilt with '
      'SHERPA_ONNXRUNTIME_LIB_DIR (docs/voice-cloning.md)',
    );
  }

  /// Load [modelPath]. Throws [StateError] with the runtime's own message on
  /// failure (a missing file, a graph the runtime can't parse).
  OrtSession loadSession(String modelPath, {int numThreads = 2}) {
    _assertLive();
    final optOut = calloc<Pointer<Void>>();
    final sessOut = calloc<Pointer<Void>>();
    final pathPtr = modelPath.toNativeUtf8();
    try {
      _check(
        _api,
        _api[_kCreateSessionOptions]
            .cast<NativeFunction<_Status Function(Pointer<Pointer<Void>>)>>()
            .asFunction<_Status Function(Pointer<Pointer<Void>>)>()(optOut),
      );
      final opts = optOut.value;
      _check(
        _api,
        _api[_kSetIntraOpNumThreads]
            .cast<NativeFunction<_Status Function(Pointer<Void>, Int32)>>()
            .asFunction<_Status Function(Pointer<Void>, int)>()(
          opts,
          numThreads,
        ),
      );
      try {
        _check(
          _api,
          _api[_kCreateSession]
              .cast<
                  NativeFunction<
                      _Status Function(Pointer<Void>, Pointer<Utf8>,
                          Pointer<Void>, Pointer<Pointer<Void>>)>>()
              .asFunction<
                  _Status Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>,
                      Pointer<Pointer<Void>>)>()(
            _env,
            pathPtr,
            opts,
            sessOut,
          ),
        );
      } finally {
        _api[_kReleaseSessionOptions]
            .cast<NativeFunction<Void Function(Pointer<Void>)>>()
            .asFunction<void Function(Pointer<Void>)>()(opts);
      }
      return OrtSession._(this, sessOut.value);
    } finally {
      calloc.free(pathPtr);
      calloc.free(optOut);
      calloc.free(sessOut);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api[_kReleaseMemoryInfo]
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>()(_memInfo);
    _api[_kReleaseEnv]
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>()(_env);
  }

  void _assertLive() {
    if (_disposed) throw StateError('OrtRuntime used after dispose');
  }

  /// Throw on a non-null `OrtStatus*`, releasing it either way.
  static void _check(Pointer<Pointer<Void>> api, _Status status) {
    if (status == nullptr) return;
    final msg = api[_kGetErrorMessage]
        .cast<NativeFunction<Pointer<Utf8> Function(Pointer<Void>)>>()
        .asFunction<Pointer<Utf8> Function(Pointer<Void>)>()(status);
    final text = msg == nullptr ? 'unknown error' : msg.toDartString();
    api[_kReleaseStatus]
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>()(status);
    throw StateError('onnxruntime: $text');
  }
}

/// One loaded graph. [run] is blocking and single-threaded — call it from the
/// worker isolate, never from the UI one.
class OrtSession {
  OrtSession._(this._rt, this._session);

  final OrtRuntime _rt;
  final Pointer<Void> _session;
  bool _disposed = false;

  /// Run the graph. [inputs] maps an input name to a `(data, shape)` pair;
  /// [outputNames] are the outputs to fetch, in order.
  ///
  /// Every buffer is copied into native memory and freed here, so the caller's
  /// typed lists can be reused immediately.
  List<OrtTensor> run(
    Map<String, OrtInput> inputs,
    List<String> outputNames,
  ) {
    if (_disposed) throw StateError('OrtSession used after dispose');
    final api = _rt._api;
    final nIn = inputs.length;
    final nOut = outputNames.length;

    final namePtrs = <Pointer<Utf8>>[];
    final dataPtrs = <Pointer<NativeType>>[];
    final shapePtrs = <Pointer<Int64>>[];
    final values = <Pointer<Void>>[];

    final inNames = calloc<Pointer<Utf8>>(nIn);
    final inValues = calloc<Pointer<Void>>(nIn);
    final outNames = calloc<Pointer<Utf8>>(nOut);
    final outValues = calloc<Pointer<Void>>(nOut);

    try {
      var i = 0;
      for (final entry in inputs.entries) {
        final name = entry.key.toNativeUtf8();
        namePtrs.add(name);
        inNames[i] = name;

        final input = entry.value;
        final shape = calloc<Int64>(input.shape.length);
        shapePtrs.add(shape);
        for (var d = 0; d < input.shape.length; d++) {
          shape[d] = input.shape[d];
        }

        final Pointer<NativeType> data;
        final int byteLength;
        final int elemType;
        if (input.floats != null) {
          final src = input.floats!;
          final p = calloc<Float>(src.length);
          p.asTypedList(src.length).setAll(0, src);
          data = p;
          byteLength = src.length * 4;
          elemType = _ortTensorElemTypeFloat;
        } else {
          final src = input.int64s!;
          final p = calloc<Int64>(src.length);
          p.asTypedList(src.length).setAll(0, src);
          data = p;
          byteLength = src.length * 8;
          elemType = _ortTensorElemTypeInt64;
        }
        dataPtrs.add(data);

        final valueOut = calloc<Pointer<Void>>();
        try {
          OrtRuntime._check(
            api,
            api[_kCreateTensorWithDataAsOrtValue]
                .cast<
                    NativeFunction<
                        _Status Function(Pointer<Void>, Pointer<Void>, Size,
                            Pointer<Int64>, Size, Int32, Pointer<Pointer<Void>>)>>()
                .asFunction<
                    _Status Function(Pointer<Void>, Pointer<Void>, int,
                        Pointer<Int64>, int, int, Pointer<Pointer<Void>>)>()(
              _rt._memInfo,
              data.cast<Void>(),
              byteLength,
              shape,
              input.shape.length,
              elemType,
              valueOut,
            ),
          );
          values.add(valueOut.value);
          inValues[i] = valueOut.value;
        } finally {
          calloc.free(valueOut);
        }
        i++;
      }

      for (var o = 0; o < nOut; o++) {
        final n = outputNames[o].toNativeUtf8();
        namePtrs.add(n);
        outNames[o] = n;
      }

      OrtRuntime._check(
        api,
        api[_kRun]
            .cast<
                NativeFunction<
                    _Status Function(
                        Pointer<Void>,
                        Pointer<Void>,
                        Pointer<Pointer<Utf8>>,
                        Pointer<Pointer<Void>>,
                        Size,
                        Pointer<Pointer<Utf8>>,
                        Size,
                        Pointer<Pointer<Void>>)>>()
            .asFunction<
                _Status Function(
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Pointer<Utf8>>,
                    Pointer<Pointer<Void>>,
                    int,
                    Pointer<Pointer<Utf8>>,
                    int,
                    Pointer<Pointer<Void>>)>()(
          _session,
          nullptr,
          inNames,
          inValues,
          nIn,
          outNames,
          nOut,
          outValues,
        ),
      );

      final result = <OrtTensor>[];
      for (var o = 0; o < nOut; o++) {
        result.add(_readTensor(api, outValues[o]));
        api[_kReleaseValue]
            .cast<NativeFunction<Void Function(Pointer<Void>)>>()
            .asFunction<void Function(Pointer<Void>)>()(outValues[o]);
      }
      return result;
    } finally {
      for (final v in values) {
        api[_kReleaseValue]
            .cast<NativeFunction<Void Function(Pointer<Void>)>>()
            .asFunction<void Function(Pointer<Void>)>()(v);
      }
      for (final p in dataPtrs) {
        calloc.free(p);
      }
      for (final p in shapePtrs) {
        calloc.free(p);
      }
      for (final p in namePtrs) {
        calloc.free(p);
      }
      calloc.free(inNames);
      calloc.free(inValues);
      calloc.free(outNames);
      calloc.free(outValues);
    }
  }

  static OrtTensor _readTensor(Pointer<Pointer<Void>> api, Pointer<Void> value) {
    final infoOut = calloc<Pointer<Void>>();
    final countOut = calloc<Size>();
    try {
      OrtRuntime._check(
        api,
        api[_kGetTensorTypeAndShape]
            .cast<
                NativeFunction<
                    _Status Function(Pointer<Void>, Pointer<Pointer<Void>>)>>()
            .asFunction<
                _Status Function(Pointer<Void>, Pointer<Pointer<Void>>)>()(
          value,
          infoOut,
        ),
      );
      final info = infoOut.value;
      try {
        OrtRuntime._check(
          api,
          api[_kGetDimensionsCount]
              .cast<
                  NativeFunction<_Status Function(Pointer<Void>, Pointer<Size>)>>()
              .asFunction<_Status Function(Pointer<Void>, Pointer<Size>)>()(
            info,
            countOut,
          ),
        );
        final rank = countOut.value;
        final dims = calloc<Int64>(rank);
        try {
          OrtRuntime._check(
            api,
            api[_kGetDimensions]
                .cast<
                    NativeFunction<
                        _Status Function(Pointer<Void>, Pointer<Int64>, Size)>>()
                .asFunction<
                    _Status Function(Pointer<Void>, Pointer<Int64>, int)>()(
              info,
              dims,
              rank,
            ),
          );
          final shape = List<int>.generate(rank, (i) => dims[i]);
          var count = 1;
          for (final d in shape) {
            count *= d;
          }
          final dataOut = calloc<Pointer<Void>>();
          try {
            OrtRuntime._check(
              api,
              api[_kGetTensorMutableData]
                  .cast<
                      NativeFunction<
                          _Status Function(
                              Pointer<Void>, Pointer<Pointer<Void>>)>>()
                  .asFunction<
                      _Status Function(Pointer<Void>, Pointer<Pointer<Void>>)>()(
                value,
                dataOut,
              ),
            );
            // Copy out: the buffer belongs to the OrtValue we release next.
            final view = dataOut.value.cast<Float>().asTypedList(count);
            return OrtTensor(Float32List.fromList(view), shape);
          } finally {
            calloc.free(dataOut);
          }
        } finally {
          calloc.free(dims);
        }
      } finally {
        api[_kReleaseTensorTypeAndShapeInfo]
            .cast<NativeFunction<Void Function(Pointer<Void>)>>()
            .asFunction<void Function(Pointer<Void>)>()(info);
      }
    } finally {
      calloc.free(infoOut);
      calloc.free(countOut);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _rt._api[_kReleaseSession]
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>()(_session);
  }
}

/// One input tensor: float32 or int64 data plus its shape.
class OrtInput {
  OrtInput.floats(Float32List data, this.shape)
      : floats = data,
        int64s = null;
  OrtInput.int64s(Int64List data, this.shape)
      : floats = null,
        int64s = data;

  final Float32List? floats;
  final Int64List? int64s;
  final List<int> shape;
}

/// A float32 output tensor, copied out of the runtime.
class OrtTensor {
  const OrtTensor(this.data, this.shape);

  final Float32List data;
  final List<int> shape;
}
