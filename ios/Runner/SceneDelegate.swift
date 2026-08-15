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

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterVC
    window.makeKeyAndVisible()
    self.window = window
  }
}
