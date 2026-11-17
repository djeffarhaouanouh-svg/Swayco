import AVFoundation
import Flutter
import UIKit
import UserNotifications

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

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    // A tapped push that COLD-launched the app can arrive HERE instead of
    // AppDelegate's launchOptions[.remoteNotification] — Scene-based apps
    // aren't guaranteed which path iOS uses to hand back the notification
    // that started the launch. Same UserDefaults key as the AppDelegate
    // capture, read back by NotificationClient.consumeColdLaunchIntent() on
    // the Dart side regardless of which of the two actually fired.
    if let response = connectionOptions.notificationResponse {
      persistPendingNotificationLaunchData(
        response.notification.request.content.userInfo)
    }

    let flutterVC = FlutterViewController()
    // Plugins must be registered on THIS FlutterViewController's
    // engine — registering on AppDelegate instead targets the implicit
    // engine and leaves every plugin channel disconnected from the
    // scene's Flutter UI (confirmed by Railway pings on 6.1.2+15).
    GeneratedPluginRegistrant.register(with: flutterVC)

    // STT taps WebRTC's existing mic capture through this channel instead of
    // opening a second `record` capture (which self-oscillates on iOS). Must be
    // registered AFTER GeneratedPluginRegistrant so flutter_webrtc's singleton
    // exists by the time Dart calls start.
    SwayMicTap.register(with: flutterVC.binaryMessenger)

    // Apple's native on-device STT, offered to Dart as a drop-in for the
    // Whisper recogniser. Same timing constraint as SwayMicTap: registered on
    // THIS engine's messenger, after the generated plugins.
    SwayAppleStt.register(with: flutterVC.binaryMessenger)

    // LECTURE SEULE de la session audio, pour le panneau de debug de l'appel :
    // où le système envoie réellement le son (écouteur, haut-parleur, casque), et
    // avec quelle catégorie / mode / options. C'est ce qui manquait pour savoir
    // si la voix de synthèse sort au même endroit que celle de l'appel. Ne
    // modifie RIEN — aucun setCategory, aucun setActive.
    let routeChannel = FlutterMethodChannel(
      name: "swayco/audio_route", binaryMessenger: flutterVC.binaryMessenger)
    routeChannel.setMethodCallHandler { call, result in
      guard call.method == "snapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let s = AVAudioSession.sharedInstance()
      let outs = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
      let ins = s.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
      let o = s.categoryOptions
      var opts: [String] = []
      if o.contains(.mixWithOthers) { opts.append("mix") }
      if o.contains(.defaultToSpeaker) { opts.append("defSpk") }
      if o.contains(.allowBluetooth) { opts.append("bt") }
      if o.contains(.allowBluetoothA2DP) { opts.append("a2dp") }
      if o.contains(.duckOthers) { opts.append("duck") }
      let vol = String(format: "%.2f", s.outputVolume)
      result(
        "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) opts=[\(opts.joined(separator: ","))] out=[\(outs)] in=[\(ins)] sysvol=\(vol)"
      )
    }

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterVC
    window.makeKeyAndVisible()
    self.window = window
  }
}
