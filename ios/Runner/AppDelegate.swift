import Flutter
import UIKit
import PushKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {
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
    //
    // We DO still set up PushKit here: it registers no Flutter plugin, it
    // only forwards VoIP events to SwiftFlutterCallkitIncomingPlugin's
    // app-wide singleton (which the scene sets up when it registers the
    // plugins). This is what lets CallKit ring on an incoming call even
    // when the app is backgrounded or killed.
    let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - PKPushRegistryDelegate (VoIP / CallKit)

  /// APNs (re)issued the device's VoIP push token. Hand it to the plugin so
  /// Dart can upload it to our backend (NotificationApi.registerVoip).
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    let deviceToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    // Persist DIRECTLY to the key the plugin reads in getDevicePushTokenVoIP
    // ("DevicePushTokenVoIP"). The plugin's own setDevicePushTokenVoIP is the
    // only thing that normally writes it, but it runs through
    // sharedInstance — which is nil here because our SceneDelegate registers
    // plugins late. That dropped the token entirely (getDevicePushTokenVoIP
    // returned "", so Dart never registered it). Writing UserDefaults
    // ourselves guarantees the token survives the race; the sharedInstance
    // call below is best-effort to also fire the Dart "token updated" event.
    UserDefaults.standard.set(deviceToken, forKey: "DevicePushTokenVoIP")
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(deviceToken)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  /// A VoIP push arrived. iOS 13+ REQUIRES reporting an incoming call to
  /// CallKit synchronously from this method (or the app is killed). The
  /// plugin does the CallKit reporting; we just translate the payload into
  /// its Data model. These keys must match what backend/notify.js puts in
  /// the VoIP payload.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    let dict = payload.dictionaryPayload
    let callId = (dict["callId"] as? String) ?? UUID().uuidString
    let callerName = (dict["callerName"] as? String) ?? "Appel entrant"
    let handle = (dict["callerId"] as? String) ?? ""
    let roomName = (dict["roomName"] as? String) ?? ""

    let data = flutter_callkit_incoming.Data(
      id: callId,
      nameCaller: callerName,
      handle: handle,
      type: 0
    )
    data.extra = [
      "callId": callId,
      "roomName": roomName,
      "callerId": handle,
    ] as NSDictionary

    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true)
    completion()
  }
}
