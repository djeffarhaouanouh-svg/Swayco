#import "SwayMicTap.h"
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/FlutterRTCAudioSink.h>

// Channel names — mirrored in sway_webrtc_mic_tap.dart.
static NSString *const kMethodChannel = @"swayco/mic_tap";
static NSString *const kEventChannel = @"swayco/mic_tap/pcm";

@interface SwayMicTap () <FlutterStreamHandler>
@property(nonatomic, strong) FlutterRTCAudioSink *sink;
@property(nonatomic, strong) FlutterMethodChannel *method;
@property(nonatomic, copy) FlutterEventSink events;
@property(nonatomic, assign) double sampleRate;   // reported to Dart once known
@property(nonatomic, assign) BOOL formatSent;
@property(nonatomic, assign) unsigned long long frames;
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
      NSString *trackId = call.arguments[@"trackId"];
      [tap startWithTrackId:trackId result:result];
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

- (void)startWithTrackId:(NSString *)trackId result:(FlutterResult)result {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (plugin == nil) {
    result([FlutterError errorWithCode:@"no_plugin"
                               message:@"flutter_webrtc singleton is nil"
                               details:nil]);
    return;
  }
  RTCMediaStreamTrack *track = [plugin trackForId:trackId peerConnectionId:nil];
  if (![track isKindOfClass:[RTCAudioTrack class]]) {
    result([FlutterError
        errorWithCode:@"no_track"
              message:[NSString stringWithFormat:@"no local audio track for id %@",
                                                 trackId]
              details:nil]);
    return;
  }

  [self stop];  // drop any previous sink
  self.frames = 0;
  self.sampleRate = 0;
  self.formatSent = NO;

  __weak SwayMicTap *weakSelf = self;
  self.sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:(RTCAudioTrack *)track];
  self.sink.bufferCallback = ^(CMSampleBufferRef buffer) {
    [weakSelf onBuffer:buffer];
  };
  result(@"started");
}

- (void)onBuffer:(CMSampleBufferRef)buffer {
  if (buffer == NULL) return;
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buffer);
  if (block == NULL) return;
  size_t length = CMBlockBufferGetDataLength(block);
  if (length == 0) return;

  NSMutableData *data = [NSMutableData dataWithLength:length];
  if (CMBlockBufferCopyDataBytes(block, 0, length, data.mutableBytes) !=
      kCMBlockBufferNoErr) {
    return;
  }

  // Learn the real rate/channels from the first buffer and hand it to Dart, so
  // the resampler there uses the true ratio instead of a guess.
  if (self.sampleRate == 0) {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(buffer);
    if (fmt) {
      const AudioStreamBasicDescription *asbd =
          CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
      if (asbd) self.sampleRate = asbd->mSampleRate;
    }
  }

  self.frames++;
  double rate = self.sampleRate;
  BOOL sendFormat = (!self.formatSent && rate > 0);
  if (sendFormat) self.formatSent = YES;
  unsigned long long n = self.frames;

  // FlutterEventSink / MethodChannel must be touched on the platform thread; the
  // sink fires on a WebRTC thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (sendFormat) {
      [self.method invokeMethod:@"format"
                      arguments:@{@"sampleRate" : @(rate)}];
      NSLog(@"[SwayMicTap] first PCM — sampleRate=%.0f", rate);
    }
    if (n % 200 == 0) {
      NSLog(@"[SwayMicTap] %llu buffers tapped", n);
    }
    FlutterEventSink sink = self.events;
    if (sink != nil) {
      sink([FlutterStandardTypedData typedDataWithBytes:data]);
    }
  });
}

- (void)stop {
  if (self.sink != nil) {
    [self.sink close];
    self.sink = nil;
  }
  self.sampleRate = 0;
  self.formatSent = NO;
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
