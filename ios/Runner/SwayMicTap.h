#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

// Taps the PCM of an already-open flutter_webrtc LOCAL audio track, instead of
// opening a SECOND `record` capture on the same mic. Two captures on one iOS mic
// self-oscillate into a startup whistle (proven on-device); this reuses the ONE
// capture WebRTC already runs, the way the web build clones the LiveKit track.
//
// Pure client of flutter_webrtc's PUBLIC API (sharedSingleton + trackForId +
// FlutterRTCAudioSink) — no fork of the plugin.
@interface SwayMicTap : NSObject

// Wire up the method + event channels on this messenger. Call once, from the
// SceneDelegate, right after the plugins are registered.
+ (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

@end
