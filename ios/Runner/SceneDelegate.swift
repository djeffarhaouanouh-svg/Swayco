import Flutter
import UIKit

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
    let flutterVC = FlutterViewController()
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterVC
    window.makeKeyAndVisible()
    self.window = window
  }
}
