import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Plugins are registered on the FlutterViewController inside
    // SceneDelegate now — the scene creates its own FlutterEngine, so
    // registering them here on AppDelegate would attach them to a
    // different engine (the implicit one), leaving the scene's engine
    // pluginless. The Railway pings on 6.1.2+15 confirmed that mistake:
    //   PlatformException(channel-error, Unable to establish connection
    //   on channel "dev.flutter.pigeon.shared_preferences_foundation
    //   .LegacyUserDefaultsApi.getAll", null, null)
    // and the same on firebase_core_platform_interface. Moving the
    // register call to the scene fixes those channel errors.
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
