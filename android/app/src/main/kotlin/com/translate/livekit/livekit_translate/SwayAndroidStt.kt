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
/// keep the last partial and return that.
///
/// PRIVACY: on-device recognition is preferred and the caller only routes here
/// for an installed on-device language; a missing model falls back to Whisper in
/// Dart. `EXTRA_PREFER_OFFLINE` is set whenever the caller demands on-device.
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

  private fun onDeviceCapable(): Boolean =
    Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "capable" -> result.success(onDeviceCapable())
      "onDeviceLanguages" -> onDeviceLanguages(result)
      "transcribe" -> transcribe(call, result)
      else -> result.notImplemented()
    }
  }

  /// Installed on-device languages, from checkRecognitionSupport (API 33+).
  private fun onDeviceLanguages(result: MethodChannel.Result) {
    if (!onDeviceCapable()) {
      result.success(emptyList<String>()); return
    }
    main.post {
      val sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
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
      // Watchdog: some builds never call back.
      main.postDelayed({ reply(emptyList()) }, 6000)
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

    val useOnDevice = requireOnDevice && onDeviceCapable()
    val t0 = SystemClock.elapsedRealtime()

    main.post {
      val sr = if (useOnDevice)
        SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
      else
        SpeechRecognizer.createSpeechRecognizer(context)

      var lastPartial = ""
      var replied = false
      val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)

      val reply = { text: String ->
        if (!replied) {
          replied = true
          busy = false
          try { sr.destroy() } catch (_: Throwable) {}
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
      }

      sr.setRecognitionListener(object : RecognitionListener {
        override fun onResults(b: Bundle) {
          val txt = b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
          // Feeding audio by file leaves the FINAL result empty on many builds
          // (no trailing silence to close the endpointer); the last partial is
          // the real transcript.
          reply(if (txt.isNotEmpty()) txt else lastPartial)
        }

        override fun onError(e: Int) {
          // NO_MATCH / SPEECH_TIMEOUT after good partials is the same empty-final
          // quirk: return what the partials captured rather than dropping it.
          reply(lastPartial)
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
      })

      val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, requireOnDevice)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pfd)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, sampleRate)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
      }
      try {
        sr.startListening(intent)
      } catch (t: Throwable) {
        reply(lastPartial)
      }
      // Watchdog: never let one clip wedge the queue if no callback fires.
      main.postDelayed({ reply(lastPartial) }, 12000)
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
