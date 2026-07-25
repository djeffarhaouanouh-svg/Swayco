package com.translate.livekit.livekit_translate

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/// Android's native on-device speech-to-text (`SpeechRecognizer`, Google's
/// engine), exposed to Dart as a drop-in for the sherpa-onnx Whisper recogniser
/// — the Android twin of `SwayAppleStt` (iOS).
///
/// It is a CLIP recogniser, matching the existing `UniversalAsrEngine`: Dart's
/// VAD segments a phrase, hands us the 16 kHz mono Float32 samples, and we
/// return the text. The whole `LocalSttMicStreamer` pipeline (VAD, merge,
/// mute/echo gate, hallucination filters) is untouched — only the `transcribe`
/// step changes.
///
/// Unlike iOS, `SpeechRecognizer` cannot be handed an audio buffer directly: we
/// write the clip to a PCM16 temp file and pass its descriptor via
/// `EXTRA_AUDIO_SOURCE` (API 33+). And the FINAL result comes back empty when
/// audio is fed this way (the endpointer never sees trailing silence), so we
/// keep the last partial.
///
/// PERSISTENT + WARM-UP: measured on Firebase Test Lab, the FIRST recognition of
/// a session pays a cold-start (~1.4 s on a Pixel 9 Pro XL) while the on-device
/// service binds and loads the model; every subsequent one is ~440 ms. So we
/// hold ONE recogniser alive for the whole call and expose `warmup`, which Dart
/// calls at connect time to run a throwaway silent recognition — the model is
/// then already loaded when the first real phrase lands.
///
/// Channel is registered from `MainActivity.configureFlutterEngine`, the Android
/// analogue of iOS's `SceneDelegate` registration.
class SwayAndroidStt(private val context: Context) {

  companion object {
    private const val CHANNEL = "swayco/android_stt"

    fun register(messenger: BinaryMessenger, context: Context) {
      val instance = SwayAndroidStt(context.applicationContext)
      MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
        instance.handle(call, result)
      }
    }
  }

  private val main = Handler(Looper.getMainLooper())

  // One recognition at a time. Dart already serialises transcribe() through its
  // _asrQueue, but a stray overlap must not crash: reject with "" while busy.
  @Volatile private var busy = false

  // The persistent recogniser, kept alive for the whole call so only the first
  // recognition pays the cold-start. Rebuilt if the on-device/cloud mode flips.
  private var recognizer: SpeechRecognizer? = null
  private var recognizerOnDevice = false

  // The reply for the recognition currently in flight, invoked by the shared
  // RecognitionListener. Touched only on the main thread.
  private var pending: ((String) -> Unit)? = null
  private var lastPartial = ""

  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "capable" -> result.success(onDeviceCapable())
      "onDeviceLanguages" -> onDeviceLanguages(result)
      "warmup" -> warmup(call, result)
      "transcribe" -> transcribe(call, result)
      "release" -> { releaseRecognizer(); result.success(null) }
      else -> result.notImplemented()
    }
  }

  /// Whether this device can actually run the on-device recogniser.
  ///
  /// `isOnDeviceRecognitionAvailable` is necessary but NOT sufficient: budget
  /// devices (seen on a Galaxy A03s, API 33) return true here yet throw
  /// `UnsupportedOperationException: On-device recognition is not available`
  /// from `createOnDeviceSpeechRecognizer`. So we actually try to build one —
  /// a false here makes Dart fall back to Whisper instead of crashing.
  /// Called on the platform (main) thread, where SpeechRecognizer must be built.
  private fun onDeviceCapable(): Boolean {
    if (Build.VERSION.SDK_INT < 33) return false
    if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) return false
    val sr = try {
      SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
    } catch (t: Throwable) {
      return false
    }
    try { sr.destroy() } catch (_: Throwable) {}
    return true
  }

  /// Installed on-device languages, from checkRecognitionSupport (API 33+).
  private fun onDeviceLanguages(result: MethodChannel.Result) {
    if (!onDeviceCapable()) {
      result.success(emptyList<String>()); return
    }
    main.post {
      val sr = try {
        SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
      } catch (t: Throwable) {
        result.success(emptyList<String>()); return@post
      }
      var replied = false
      val reply = { v: List<String> ->
        if (!replied) {
          replied = true
          try { sr.destroy() } catch (_: Throwable) {}
          result.success(v)
        }
      }
      try {
        sr.checkRecognitionSupport(
          Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
          Executors.newSingleThreadExecutor(),
          object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
              main.post { reply(support.installedOnDeviceLanguages) }
            }
            override fun onError(error: Int) {
              main.post { reply(emptyList()) }
            }
          },
        )
      } catch (t: Throwable) {
        reply(emptyList())
      }
      main.postDelayed({ reply(emptyList()) }, 6000)
    }
  }

  /// The shared listener for the persistent recogniser: routes each result to
  /// whatever [pending] reply is in flight, keeping the last partial as the real
  /// transcript (the final comes back empty when audio is fed by file).
  private fun makeListener() = object : RecognitionListener {
    override fun onResults(b: Bundle) {
      val txt = b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
      val p = pending; pending = null
      p?.invoke(if (txt.isNotEmpty()) txt else lastPartial)
    }
    override fun onError(e: Int) {
      // NO_MATCH / SPEECH_TIMEOUT after good partials is the empty-final quirk:
      // return what the partials captured rather than dropping it.
      val p = pending; pending = null
      p?.invoke(lastPartial)
    }
    override fun onPartialResults(p: Bundle) {
      val txt = p.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
      if (!txt.isNullOrEmpty()) lastPartial = txt
    }
    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
  }

  /// Return the live recogniser for [useOnDevice], building it (and its listener)
  /// once and reusing it. Null when the on-device recogniser refuses to build
  /// (budget device) — the caller then degrades gracefully. Main thread only.
  private fun ensureRecognizer(useOnDevice: Boolean): SpeechRecognizer? {
    val existing = recognizer
    if (existing != null && recognizerOnDevice == useOnDevice) return existing
    existing?.let { try { it.destroy() } catch (_: Throwable) {} }
    recognizer = null
    val sr = try {
      if (useOnDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
      else SpeechRecognizer.createSpeechRecognizer(context)
    } catch (t: Throwable) {
      return null
    }
    sr.setRecognitionListener(makeListener())
    recognizer = sr
    recognizerOnDevice = useOnDevice
    return sr
  }

  private fun releaseRecognizer() {
    main.post {
      pending = null
      recognizer?.let { try { it.destroy() } catch (_: Throwable) {} }
      recognizer = null
    }
  }

  private fun intentFor(locale: String, pfd: ParcelFileDescriptor, sampleRate: Int, preferOffline: Boolean): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, preferOffline)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pfd)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, sampleRate)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
    }

  /// Load the on-device model ahead of the first real phrase by running a
  /// throwaway recognition on ~300 ms of silence. Called by Dart at call connect.
  /// Args: locale, requireOnDevice. Returns true if the recogniser is up.
  private fun warmup(call: MethodCall, result: MethodChannel.Result) {
    val locale = call.argument<String>("locale") ?: return result.success(false)
    val requireOnDevice = call.argument<Boolean>("requireOnDevice") ?: true
    if (Build.VERSION.SDK_INT < 33) { result.success(false); return }
    if (busy) { result.success(true); return } // already working ⇒ already warm

    val file: File
    try {
      file = File.createTempFile("warm", ".pcm", context.cacheDir)
      file.writeBytes(ByteArray(16000 * 2 * 300 / 1000)) // 300 ms of silence
    } catch (t: Throwable) {
      result.success(false); return
    }

    busy = true
    main.post {
      val sr = ensureRecognizer(requireOnDevice)
      if (sr == null) {
        busy = false; try { file.delete() } catch (_: Throwable) {}
        result.success(false); return@post
      }
      lastPartial = ""
      val pfd = try {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
      } catch (t: Throwable) {
        busy = false; try { file.delete() } catch (_: Throwable) {}
        result.success(false); return@post
      }
      var done = false
      val finish = fun(_: String) {
        if (done) return
        done = true
        pending = null
        busy = false
        try { pfd.close() } catch (_: Throwable) {}
        try { file.delete() } catch (_: Throwable) {}
        result.success(true)
      }
      pending = finish
      try {
        sr.startListening(intentFor(locale, pfd, 16000, requireOnDevice))
      } catch (t: Throwable) {
        finish("")
      }
      // Cold-start can be ~1.4 s; give it room.
      main.postDelayed({ finish("") }, 10000)
    }
  }

  /// Transcribe one clip. Args:
  ///   locale: String (e.g. "fr-FR")
  ///   samples: ByteArray — Float32 little-endian, mono, [-1, 1]
  ///   sampleRate: Int (16000)
  ///   requireOnDevice: Bool — prefer offline / on-device recogniser
  /// Returns { text: String, ms: Int, onDevice: Bool }.
  private fun transcribe(call: MethodCall, result: MethodChannel.Result) {
    val locale = call.argument<String>("locale")
    val samples = call.argument<ByteArray>("samples")
    val sampleRate = call.argument<Int>("sampleRate") ?: 16000
    val requireOnDevice = call.argument<Boolean>("requireOnDevice") ?: true
    if (locale == null || samples == null) {
      result.error("bad_args", "locale/samples required", null); return
    }
    if (Build.VERSION.SDK_INT < 33) {
      result.error("unsupported", "SpeechRecognizer audio-source needs API 33", null); return
    }
    if (busy) {
      result.success(mapOf("text" to "", "ms" to 0, "onDevice" to false)); return
    }
    busy = true

    val pcm = float32ToPcm16(samples)
    if (pcm.isEmpty()) {
      busy = false
      result.success(mapOf("text" to "", "ms" to 0, "onDevice" to false)); return
    }
    val file: File
    try {
      file = File.createTempFile("stt", ".pcm", context.cacheDir)
      file.writeBytes(pcm)
    } catch (t: Throwable) {
      busy = false
      result.error("io", t.message ?: "write failed", null); return
    }

    val useOnDevice = requireOnDevice
    val t0 = SystemClock.elapsedRealtime()

    main.post {
      val sr = ensureRecognizer(useOnDevice)
      if (sr == null) {
        // On-device recogniser refused to build (budget device that lies about
        // availability). Give up this clip gracefully; the language load already
        // fell back to Whisper via capable().
        busy = false; try { file.delete() } catch (_: Throwable) {}
        result.success(mapOf("text" to "", "ms" to 0, "onDevice" to false)); return@post
      }
      lastPartial = ""
      val pfd = try {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
      } catch (t: Throwable) {
        busy = false; try { file.delete() } catch (_: Throwable) {}
        result.success(mapOf("text" to "", "ms" to 0, "onDevice" to false)); return@post
      }
      var replied = false
      val finish = fun(text: String) {
        if (replied) return
        replied = true
        pending = null
        busy = false
        try { pfd.close() } catch (_: Throwable) {}
        try { file.delete() } catch (_: Throwable) {}
        result.success(
          mapOf(
            "text" to text,
            "ms" to (SystemClock.elapsedRealtime() - t0).toInt(),
            "onDevice" to useOnDevice,
          ),
        )
      }
      pending = finish
      try {
        sr.startListening(intentFor(locale, pfd, sampleRate, requireOnDevice))
      } catch (t: Throwable) {
        finish(lastPartial)
      }
      // Watchdog: never let one clip wedge the queue if no callback fires.
      main.postDelayed({ finish(lastPartial) }, 12000)
    }
  }

  /// Float32 LE [-1,1] bytes -> PCM16 LE bytes.
  private fun float32ToPcm16(bytes: ByteArray): ByteArray {
    val n = bytes.size / 4
    if (n == 0) return ByteArray(0)
    val src = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    val out = ByteArray(n * 2)
    val dst = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
    for (i in 0 until n) {
      var s = src.float
      if (s > 1f) s = 1f
      if (s < -1f) s = -1f
      dst.putShort((s * 32767f).toInt().toShort())
    }
    return out
  }
}
