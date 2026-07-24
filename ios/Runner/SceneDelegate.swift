import Flutter
import UIKit
import AVFoundation

/// Scene-based window setup for Flutter on iOS 13+. Instantiating the
/// FlutterViewController programmatically from `willConnectTo` and
/// attaching it to a `UIWindow(windowScene:)` is the only setup that
/// gives Flutter a properly connected UIScreen on iOS 26.x — the
/// storyboard-driven legacy path (UIMainStoryboardFile) was leaving the
/// view at 0×0 with `MediaQuery devicePixelRatio = 1.0`, even when the
/// AppDelegate fallback recreated a window manually. Confirmed via
/// Railway pings (`capture-media-query w=0.0 h=0.0`).
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var audioChannel: FlutterMethodChannel?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let flutterVC = FlutterViewController()
    // Plugins must be registered on THIS FlutterViewController's
    // engine — registering on AppDelegate instead targets the implicit
    // engine and leaves every plugin channel disconnected from the
    // scene's Flutter UI (confirmed by Railway pings on 6.1.2+15).
    GeneratedPluginRegistrant.register(with: flutterVC)

    // Mic input-gain control, for the "my mic is too hot, the peer hears
    // everything" case. AVAudioSession.setInputGain is the ONLY hardware input
    // level iOS exposes, and only when the device reports isInputGainSettable —
    // which most iPhones do NOT. Every call returns a human-readable status so
    // the in-app DebugOverlay can show whether it took or was refused, rather
    // than the change failing invisibly.
    let channel = FlutterMethodChannel(
      name: "swayco/audio", binaryMessenger: flutterVC.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setInputGain":
        let session = AVAudioSession.sharedInstance()
        guard session.isInputGainSettable else {
          result("input gain NOT settable on this device "
            + "(fixed at \(session.inputGain))")
          return
        }
        let gain = (call.arguments as? [String: Any])?["gain"] as? Double ?? 1.0
        do {
          try session.setInputGain(Float(gain))
          result("input gain set to \(gain) (was settable)")
        } catch {
          result("setInputGain threw: \(error.localizedDescription)")
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.audioChannel = channel

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterVC
    window.makeKeyAndVisible()
    self.window = window
  }
}
