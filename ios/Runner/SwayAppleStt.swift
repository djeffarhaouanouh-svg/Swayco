import Foundation
import Flutter
import Speech
import AVFoundation

/// Apple's native on-device speech-to-text (`SFSpeechRecognizer`), exposed to
/// Dart as a drop-in for the sherpa-onnx Whisper recogniser.
///
/// It is a CLIP recogniser, matching the existing `UniversalAsrEngine`: Dart's
/// VAD segments a phrase, hands us the 16 kHz mono samples, and we return the
/// text. The whole `LocalSttMicStreamer` pipeline (VAD, merge, mute/echo gate,
/// hallucination filters) is untouched — only the `transcribe` step changes.
///
/// PRIVACY: every request sets `requiresOnDeviceRecognition = true`. If the
/// on-device asset for a language is not installed, `supportsOnDeviceRecognition`
/// is false and Dart never routes here — it falls back to the bundled Whisper,
/// which is always on-device. So mic audio still never leaves the phone.
///
/// Channel is registered from `SceneDelegate`, after the generated plugins, the
/// same place and way as `SwayMicTap`.
class SwayAppleStt: NSObject {
  private static let channelName = "swayco/apple_stt"

  // One recognition at a time. Dart already serialises transcribe() through its
  // _asrQueue, but a stray overlap must not crash: we reject with "" while busy.
  private var busy = false
  private var recognizers: [String: SFSpeechRecognizer] = [:]
  // The task and request are held for the lifetime of one transcription so ARC
  // does not release them mid-flight.
  private var task: SFSpeechRecognitionTask?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = SwayAppleStt()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result)
    }
  }

  private func recognizer(for locale: String) -> SFSpeechRecognizer? {
    if let r = recognizers[locale] { return r }
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return nil }
    recognizers[locale] = r
    return r
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "authStatus":
      result(SFSpeechRecognizer.authorizationStatus().rawValue)

    case "requestAuth":
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async { result(status.rawValue) }
      }

    case "supportedLocales":
      let ids = SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
      result(ids)

    case "onDevice":
      guard let args = call.arguments as? [String: Any],
            let locale = args["locale"] as? String else {
        result(FlutterError(code: "bad_args", message: "locale required", details: nil)); return
      }
      let rec = recognizer(for: locale)
      result(rec?.supportsOnDeviceRecognition ?? false)

    case "available":
      guard let args = call.arguments as? [String: Any],
            let locale = args["locale"] as? String else {
        result(FlutterError(code: "bad_args", message: "locale required", details: nil)); return
      }
      result(recognizer(for: locale)?.isAvailable ?? false)

    case "transcribe":
      transcribe(call, result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// How many rival transcriptions to hand Dart. The repair model only needs
  /// enough to see WHERE the recogniser hesitated; past two or three the extra
  /// candidates are near-duplicates of each other and pure prompt cost.
  private static let maxAlternatives = 3

  /// Below this score a word is worth flagging to the repair model. Apple's
  /// confidence runs 0...1 and is 0 for anything it did not score at all, which
  /// is why the filter below demands a score strictly greater than zero: an
  /// unscored word must read as "no information", never as "certainly wrong".
  private static let shakyBelow: Float = 0.5

  /// The rival transcriptions of the same audio, best excluded.
  ///
  /// `SFSpeechRecognitionResult.transcriptions` is the n-best list; only
  /// `bestTranscription` used to be read and the rest was dropped on the floor.
  /// Identical strings are filtered out — the list often repeats the winner with
  /// different segment timings, which tells the repair model nothing.
  private static func alternatives(of res: SFSpeechRecognitionResult) -> [String] {
    let best = res.bestTranscription.formattedString
    var seen: Set<String> = [best]
    var out: [String] = []
    for t in res.transcriptions {
      let s = t.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty || seen.contains(s) { continue }
      seen.insert(s)
      out.append(s)
      if out.count >= maxAlternatives { break }
    }
    return out
  }

  /// The words in the winning transcription that Apple itself was least sure of,
  /// read from each `SFTranscriptionSegment.confidence`.
  ///
  /// This is the per-word doubt signal the ONNX recogniser could not produce at
  /// all: it says not just THAT the sentence may be wrong but WHERE. On-device
  /// assets do not always score their segments — in that case every confidence
  /// is 0, this returns empty, and downstream reads it as "no information".
  private static func shakyWords(in t: SFTranscription) -> [String] {
    t.segments
      .filter { $0.confidence > 0 && $0.confidence < shakyBelow }
      .map { $0.substring }
      .filter { !$0.isEmpty }
  }

  /// Transcribe one clip. Args:
  ///   locale: String (e.g. "fr-FR")
  ///   samples: FlutterStandardTypedData — Float32 little-endian, mono, [-1, 1]
  ///   sampleRate: Int (16000)
  /// Returns { text: String, ms: Int, alts: [String], lowConf: [String] } —
  /// ms is the native decode time, `alts` the rival hypotheses (best excluded)
  /// and `lowConf` the words scored below `shakyBelow`.
  private func transcribe(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let locale = args["locale"] as? String,
          let data = (args["samples"] as? FlutterStandardTypedData)?.data,
          let sampleRate = args["sampleRate"] as? Int else {
      result(FlutterError(code: "bad_args", message: "locale/samples/sampleRate required", details: nil))
      return
    }

    if SFSpeechRecognizer.authorizationStatus() != .authorized {
      result(FlutterError(code: "not_authorized", message: "speech not authorized", details: nil))
      return
    }
    guard let rec = recognizer(for: locale), rec.isAvailable else {
      result(FlutterError(code: "unavailable", message: "recognizer unavailable for \(locale)", details: nil))
      return
    }
    let requireOnDevice = (args["requireOnDevice"] as? Bool) ?? true
    let onDevice = rec.supportsOnDeviceRecognition
    if requireOnDevice && !onDevice {
      // Caller demanded on-device but the asset is missing. Refuse rather than
      // silently send audio to Apple's servers.
      result(FlutterError(code: "not_on_device", message: "no on-device asset for \(locale)", details: nil))
      return
    }
    if busy {
      // Mirror UniversalAsrEngine's `if (_busy) return ''` — drop, don't queue.
      result(["text": "", "ms": 0])
      return
    }

    let n = data.count / MemoryLayout<Float>.size
    if n == 0 { result(["text": "", "ms": 0]); return }

    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Double(sampleRate),
                                     channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(n)) else {
      result(FlutterError(code: "buffer", message: "could not build PCM buffer", details: nil))
      return
    }
    buffer.frameLength = AVAudioFrameCount(n)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      if let src = raw.bindMemory(to: Float.self).baseAddress,
         let dst = buffer.floatChannelData?[0] {
        dst.update(from: src, count: n)
      }
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    // Use on-device when the asset is present; otherwise (only reached when the
    // caller allowed it) fall back to Apple's cloud so the language is testable.
    request.requiresOnDeviceRecognition = onDevice
    request.shouldReportPartialResults = false
    if #available(iOS 16.0, *) {
      request.addsPunctuation = true
    }
    request.append(buffer)
    request.endAudio()

    busy = true
    let t0 = Date()
    var replied = false
    // The recognition callback and the watchdog run on different queues; hop
    // both onto main so the `replied` guard is race-free and FlutterResult is
    // invoked exactly once (calling it twice crashes the engine).
    let reply: (Any?) -> Void = { [weak self] value in
      DispatchQueue.main.async {
        if replied { return }
        replied = true
        self?.busy = false
        self?.task = nil
        result(value)
      }
    }

    task = rec.recognitionTask(with: request) { res, error in
      if let error = error {
        // A clip of pure silence/noise finalises as an error on some iOS builds;
        // treat that as "nothing recognised", not a hard failure.
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" {
          reply(["text": "", "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        } else {
          // Le message d'Apple seul ne dit pas QUI refuse : « Siri and
          // Dictation are disabled » sort de plusieurs sous-systèmes, et on
          // finit par accuser un réglage au hasard. On joint le domaine, le
          // code et l'état du recogniser au moment du refus — c'est ce triplet
          // qui désigne le coupable sans avoir à fouiller les Réglages.
          let auth = SFSpeechRecognizer.authorizationStatus().rawValue
          let diag = "[\(ns.domain) \(ns.code)] auth=\(auth) " +
            "available=\(rec.isAvailable) onDevice=\(rec.supportsOnDeviceRecognition) " +
            "required=\(request.requiresOnDeviceRecognition) locale=\(locale)"
          reply(FlutterError(
            code: "recognition",
            message: "\(error.localizedDescription) \(diag)",
            details: nil))
        }
        return
      }
      guard let res = res, res.isFinal else { return }
      let ms = Int(Date().timeIntervalSince(t0) * 1000)
      let best = res.bestTranscription
      reply([
        "text": best.formattedString,
        "ms": ms,
        "alts": Self.alternatives(of: res),
        "lowConf": Self.shakyWords(in: best),
      ])
    }

    // Watchdog: never let one clip wedge the queue if the callback never fires.
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
      if !replied {
        self?.task?.cancel()
        reply(["text": "", "ms": 12000])
      }
    }
  }
}
