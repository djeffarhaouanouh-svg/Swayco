import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let didLaunch = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions)

    // Fallback window setup. Without UIApplicationSceneManifest in
    // Info.plist (we dropped it in 17209fb), iOS is supposed to auto-
    // create the window from UIMainStoryboardFile = "Main". On 6.1.2+10
    // Railway showed `RenderRepaintBoundary.toImage` throwing
    // "Invalid image dimensions" — i.e. the FlutterView is rendering
    // into a 0×0 area — which is exactly what happens when iOS's auto-
    // window flow silently no-ops on certain device/OS combinations.
    // If FlutterAppDelegate's super call didn't end up with a sized
    // window, instantiate the storyboard's initial VC ourselves and
    // hand it a UIWindow that actually has the screen's bounds.
    if window == nil || window?.bounds.isEmpty == true {
      let storyboard = UIStoryboard(name: "Main", bundle: nil)
      if let rootVC = storyboard.instantiateInitialViewController() {
        let win: UIWindow
        if let scene = application.connectedScenes
          .first(where: { $0.activationState == .foregroundActive
            || $0.activationState == .foregroundInactive }) as? UIWindowScene {
          win = UIWindow(windowScene: scene)
          win.frame = scene.coordinateSpace.bounds
        } else {
          win = UIWindow(frame: UIScreen.main.bounds)
        }
        win.rootViewController = rootVC
        win.makeKeyAndVisible()
        window = win
      }
    }

    return didLaunch
  }
}
