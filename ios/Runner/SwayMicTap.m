#import "SwayMicTap.h"
#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/AudioManager.h>
#import <flutter_webrtc/AudioProcessingAdapter.h>

// Channel names — mirrored in sway_webrtc_mic_tap.dart.
static NSString *const kMethodChannel = @"swayco/mic_tap";
static NSString *const kEventChannel = @"swayco/mic_tap/pcm";

// The FIRST attempt used FlutterRTCAudioSink (AddSink on the track's source).
// It attached without error and never delivered a single buffer: in libwebrtc
// only REMOTE audio sources feed their sinks — a local mic source's AddSink is a
// no-op, which is why the plugin's own MediaRecorder only uses it for remote
// tracks. The capture POST-PROCESSING hook below is the local-audio equivalent,
// and it is what LocalAudioTrack.addProcessing: forwards to.
@interface SwayMicTap () <FlutterStreamHandler, ExternalAudioProcessingDelegate>
@property(nonatomic, strong) FlutterMethodChannel *method;
@property(nonatomic, copy) FlutterEventSink events;
@property(nonatomic, assign) BOOL attached;
@property(nonatomic, assign) double sampleRate;
@property(nonatomic, assign) BOOL formatSent;
@property(nonatomic, assign) unsigned long long buffers;
@end

@implementation SwayMicTap

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

// No track id: the capture adapter is global to the WebRTC audio pipeline, so it
// survives the track being restarted (which happens on every unmute — the old
// per-track attach had to be redone each time).
- (void)start {
  if (self.attached) return;
  self.buffers = 0;
  self.sampleRate = 0;
  self.formatSent = NO;
  [AudioManager.sharedInstance.capturePostProcessingAdapter addProcessing:self];
  self.attached = YES;
  NSLog(@"[SwayMicTap] attached to capture post-processing");
}

- (void)stop {
  if (!self.attached) return;
  [AudioManager.sharedInstance.capturePostProcessingAdapter removeProcessing:self];
  self.attached = NO;
  self.sampleRate = 0;
  self.formatSent = NO;
  NSLog(@"[SwayMicTap] detached (%llu buffers)", self.buffers);
}

#pragma mark - ExternalAudioProcessingDelegate

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz
                                       channels:(size_t)channels {
  self.sampleRate = (double)sampleRateHz;
  NSLog(@"[SwayMicTap] init rate=%zu ch=%zu", sampleRateHz, channels);
}

// Runs on WebRTC's audio thread — keep it short. Channel 0 only: the recogniser
// is mono, and the second channel of a stereo capture carries nothing it needs.
- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  const size_t frames = audioBuffer.frames;
  if (frames == 0 || audioBuffer.channels == 0) return;
  const float *src = [audioBuffer rawBufferForChannel:0];
  if (src == NULL) return;

  // The plugin's own toPCMBuffer: assigns float→int16 straight across, so these
  // floats are already on the int16 scale (±32768), NOT normalised to ±1.
  NSMutableData *data = [NSMutableData dataWithLength:frames * sizeof(int16_t)];
  int16_t *dst = (int16_t *)data.mutableBytes;
  for (size_t i = 0; i < frames; i++) {
    float v = src[i];
    if (v > 32767.0f) v = 32767.0f;
    if (v < -32768.0f) v = -32768.0f;
    dst[i] = (int16_t)v;
  }

  // A buffer is one 10 ms slice, so the rate follows from its length when the
  // initialize callback never came (we may attach after the APM is up).
  if (self.sampleRate <= 0) self.sampleRate = (double)frames * 100.0;

  self.buffers++;
  const double rate = self.sampleRate;
  const BOOL sendFormat = (!self.formatSent && rate > 0);
  if (sendFormat) self.formatSent = YES;
  const unsigned long long n = self.buffers;

  // Flutter channels are platform-thread only.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (sendFormat) {
      [self.method invokeMethod:@"format" arguments:@{@"sampleRate" : @(rate)}];
      NSLog(@"[SwayMicTap] first PCM — rate=%.0f frames=%zu", rate, frames);
    }
    if (n % 500 == 0) NSLog(@"[SwayMicTap] %llu buffers", n);
    FlutterEventSink sink = self.events;
    if (sink != nil) sink([FlutterStandardTypedData typedDataWithBytes:data]);
  });
}

- (void)audioProcessingRelease {
  NSLog(@"[SwayMicTap] audio processing released");
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
