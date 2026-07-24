#import "SwayMicTap.h"
#import <stdatomic.h>
#import <stdlib.h>
#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/AudioManager.h>
#import <flutter_webrtc/AudioProcessingAdapter.h>

// Channel names — mirrored in sway_webrtc_mic_tap.dart.
static NSString *const kMethodChannel = @"swayco/mic_tap";
static NSString *const kEventChannel = @"swayco/mic_tap/pcm";

// Ring capacity in samples — a power of two so the index wraps with a mask
// rather than a modulo. 131072 @ 48 kHz ≈ 2.7 s, far more than the 100 ms drain
// below can ever fall behind by.
static const size_t kRingCapacity = 1 << 17;
static const size_t kRingMask = kRingCapacity - 1;

// How often the main thread drains. 100 ms rather than a hand-off per 10 ms
// buffer: ten times fewer thread crossings, and the recogniser does not care —
// its VAD segments on silence, not on buffer boundaries.
static const NSTimeInterval kDrainInterval = 0.1;

// Reads the mic PCM WebRTC has ALREADY captured, so the STT never opens a SECOND
// capture on the same microphone.
//
// Two earlier attempts, and what they taught:
//
//  1. FlutterRTCAudioSink (AddSink on the track's source) attached cleanly and
//     delivered nothing — in libwebrtc only REMOTE audio sources feed their
//     sinks. The capture post-processing hook used here is the local equivalent,
//     and is what LocalAudioTrack.addProcessing: forwards to.
//  2. The right hook, but the work was done INSIDE audioProcessingProcess::
//     an NSMutableData allocation, a per-sample conversion and a dispatch_async,
//     every 10 ms, on WebRTC's REAL-TIME capture thread and under the adapter's
//     lock. That starves the capture thread, and the caller's voice stopped
//     reaching the peer altogether.
//
// So: nothing in that callback may allocate, lock, or cross threads. It converts
// into a pre-allocated ring and bumps one atomic index; a main-thread timer does
// everything else.
@interface SwayMicTap () <FlutterStreamHandler, ExternalAudioProcessingDelegate>
@property(nonatomic, strong) FlutterMethodChannel *method;
@property(nonatomic, copy) FlutterEventSink events;
@property(nonatomic, strong) NSTimer *drain;
@property(nonatomic, assign) BOOL attached;
@property(nonatomic, assign) double sampleRate;
@property(nonatomic, assign) BOOL formatSent;
@end

@implementation SwayMicTap {
  int16_t *_ring;            // allocated once, never resized
  _Atomic(uint64_t) _write;  // total samples written, monotonic
  uint64_t _read;            // total samples drained; main thread only
}

+ (instancetype)shared {
  static SwayMicTap *inst;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    inst = [SwayMicTap new];
  });
  return inst;
}

+ (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  SwayMicTap *tap = [SwayMicTap shared];

  FlutterMethodChannel *method =
      [FlutterMethodChannel methodChannelWithName:kMethodChannel
                                  binaryMessenger:messenger];
  tap.method = method;
  [method setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if ([call.method isEqualToString:@"start"]) {
      [tap start];
      result(@"started");
    } else if ([call.method isEqualToString:@"stop"]) {
      [tap stop];
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }];

  FlutterEventChannel *event =
      [FlutterEventChannel eventChannelWithName:kEventChannel
                                binaryMessenger:messenger];
  [event setStreamHandler:tap];
}

// Called from the method channel, i.e. already on the platform thread.
- (void)start {
  if (self.attached) return;
  if (_ring == NULL) _ring = (int16_t *)calloc(kRingCapacity, sizeof(int16_t));
  if (_ring == NULL) {
    NSLog(@"[SwayMicTap] ring allocation failed");
    return;
  }
  atomic_store(&_write, 0);
  _read = 0;
  self.sampleRate = 0;
  self.formatSent = NO;

  [AudioManager.sharedInstance.capturePostProcessingAdapter addProcessing:self];
  self.attached = YES;

  self.drain = [NSTimer scheduledTimerWithTimeInterval:kDrainInterval
                                                target:self
                                              selector:@selector(onDrain)
                                              userInfo:nil
                                               repeats:YES];
  NSLog(@"[SwayMicTap] attached to capture post-processing");
}

- (void)stop {
  if (!self.attached) return;
  [AudioManager.sharedInstance.capturePostProcessingAdapter removeProcessing:self];
  self.attached = NO;
  [self.drain invalidate];
  self.drain = nil;
  self.sampleRate = 0;
  self.formatSent = NO;
  NSLog(@"[SwayMicTap] detached (%llu samples)",
        (unsigned long long)atomic_load(&_write));
}

#pragma mark - ExternalAudioProcessingDelegate

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz
                                       channels:(size_t)channels {
  self.sampleRate = (double)sampleRateHz;
  NSLog(@"[SwayMicTap] init rate=%zu ch=%zu", sampleRateHz, channels);
}

// REAL-TIME THREAD. Bounded work only: convert and store. No malloc, no lock, no
// dispatch — see the note at the top of this file for what happens otherwise.
- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  const size_t frames = audioBuffer.frames;
  if (frames == 0 || audioBuffer.channels == 0 || _ring == NULL) return;
  const float *src = [audioBuffer rawBufferForChannel:0];
  if (src == NULL) return;

  // A buffer is one 10 ms slice, so its length gives the rate when the
  // initialize callback never came (we can attach after the APM is already up).
  if (self.sampleRate <= 0) self.sampleRate = (double)frames * 100.0;

  const uint64_t w = atomic_load_explicit(&_write, memory_order_relaxed);
  for (size_t i = 0; i < frames; i++) {
    // The plugin's own toPCMBuffer: assigns float→int16 straight across, so
    // these floats are already on the int16 scale (±32768), not normalised.
    float v = src[i];
    if (v > 32767.0f) v = 32767.0f;
    if (v < -32768.0f) v = -32768.0f;
    _ring[(w + i) & kRingMask] = (int16_t)v;
  }
  atomic_store_explicit(&_write, w + frames, memory_order_release);
}

- (void)audioProcessingRelease {
  NSLog(@"[SwayMicTap] audio processing released");
}

#pragma mark - Drain (main thread)

- (void)onDrain {
  const uint64_t w = atomic_load_explicit(&_write, memory_order_acquire);
  if (w <= _read) return;

  // Only reachable if the main thread stalled for seconds. Drop the stale part
  // rather than read samples the writer has already overwritten.
  if (w - _read > kRingCapacity) _read = w - kRingCapacity;

  const size_t n = (size_t)(w - _read);
  NSMutableData *data = [NSMutableData dataWithLength:n * sizeof(int16_t)];
  int16_t *dst = (int16_t *)data.mutableBytes;
  for (size_t i = 0; i < n; i++) {
    dst[i] = _ring[(_read + i) & kRingMask];
  }
  _read = w;

  if (!self.formatSent && self.sampleRate > 0) {
    self.formatSent = YES;
    [self.method invokeMethod:@"format"
                    arguments:@{@"sampleRate" : @(self.sampleRate)}];
    NSLog(@"[SwayMicTap] first PCM — rate=%.0f", self.sampleRate);
  }
  FlutterEventSink sink = self.events;
  if (sink != nil) sink([FlutterStandardTypedData typedDataWithBytes:data]);
}

#pragma mark - FlutterStreamHandler

- (FlutterError *)onListenWithArguments:(id)arguments
                              eventSink:(FlutterEventSink)events {
  self.events = events;
  return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
  self.events = nil;
  return nil;
}

@end
