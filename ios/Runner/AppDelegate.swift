import Flutter
import UIKit
import PushKit
import CallKit
import flutter_callkit_incoming
import WebRTC
import FirebaseCore
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {
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

    // mixWithOthers was here to let TWO live WebRTC flows (the LiveKit voice +
    // the old OpenAI translation) play together instead of iOS silencing one.
    // That second WebRTC flow is gone — the translation is on-device TTS now — so
    // the reason for it is gone, and its cost is not: mixWithOthers makes iOS
    // hand the session to a shared, weakened voice-processing path, so its echo
    // canceller no longer copes with a hot mic (the 15 Pro's) and leaks a
    // decaying echo of the caller's own voice into the outgoing stream. WhatsApp
    // takes the session for itself and keeps full echo cancellation; without
    // mixWithOthers we do the same. Both configurators must agree — see the
    // matching change in audio_controller.dart.
    let rtcConfig = RTCAudioSessionConfiguration.webRTC()
    rtcConfig.category = AVAudioSession.Category.playAndRecord.rawValue
    rtcConfig.categoryOptions = [
      .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP,
    ]
    rtcConfig.mode = AVAudioSession.Mode.videoChat.rawValue
    RTCAudioSessionConfiguration.setWebRTC(rtcConfig)

    // Proactively ask APNs for the REGULAR device token at launch. firebase_
    // messaging normally triggers this, but our plugins live in the Scene-
    // Delegate's engine so that path is unreliable here — without the token FCM
    // never mints one and message pushes never arrive (the in-app diagnostic
    // showed "APNs: AUCUN"). The token lands in didRegister...DeviceToken below.
    // Harmless before the permission prompt; it just fetches the token early.
    UserDefaults.standard.set("registerForRemoteNotifications() appelé",
                              forKey: "flutter.apns_native_status")
    application.registerForRemoteNotifications()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // The REGULAR APNs device token is delivered here (not the VoIP token —
  // PushKit handles that separately). Our Flutter plugins live in the
  // SceneDelegate's engine, so Firebase's method swizzling doesn't reliably
  // capture this token. Hand it to FCM explicitly; without it getToken()
  // fails with "apns-token-not-set" and no FCM target is ever registered, so
  // message pushes never arrive while VoIP/CallKit calls (a separate APNs
  // path) still do.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
  ) {
    UserDefaults.standard.set(
      "token APNs reçu (\(deviceToken.count) octets)",
      forKey: "flutter.apns_native_status")
    forwardAPNsTokenToFirebase(deviceToken)
    super.application(
      application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  // Registration can fail (no aps-environment entitlement, no network, etc.).
  // Record the reason so the in-app diagnostic can surface it instead of a
  // silent "APNs: AUCUN".
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    UserDefaults.standard.set(
      "ÉCHEC registerForRemoteNotifications: \(error.localizedDescription)",
      forKey: "flutter.apns_native_status")
    super.application(
      application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // Firebase is configured asynchronously from Dart (Firebase.initializeApp in
  // main()), so the APNs token can arrive a hair before it's ready. Retry on
  // the main queue (up to ~10s) until FirebaseApp exists, then hand the token
  // to FCM — fixes the timing race where the token was dropped and never
  // re-delivered.
  private func forwardAPNsTokenToFirebase(
    _ token: Foundation.Data, retriesLeft: Int = 20
  ) {
    if FirebaseApp.app() != nil {
      Messaging.messaging().apnsToken = token
      UserDefaults.standard.set(
        "token APNs transmis à Firebase ✅",
        forKey: "flutter.apns_native_status")
      return
    }
    if retriesLeft > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.forwardAPNsTokenToFirebase(token, retriesLeft: retriesLeft - 1)
      }
    } else {
      UserDefaults.standard.set(
        "token APNs reçu mais FirebaseApp jamais prêt",
        forKey: "flutter.apns_native_status")
    }
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
  /// CallKit synchronously from this method (or the app is killed and future
  /// VoIP pushes are throttled). The plugin does the CallKit reporting; we
  /// just translate the payload into its Data model. These keys must match
  /// what backend/notify.js puts in the VoIP payload (type, callId, roomName,
  /// callerId, callerName).
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    let dict = payload.dictionaryPayload
    let pushType = (dict["type"] as? String) ?? "incoming_call"
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

    // The caller gave up before pickup: backend/notify.js sent a 'call_cancel'
    // VoIP push so a fully-killed phone stops ringing. We CANNOT just end the
    // CallKit call — iOS 13+ still demands that EVERY VoIP push report a new
    // incoming call synchronously, or it kills us and throttles the transport.
    // So we honour the contract by reporting the call and then, the instant the
    // report lands, ending it. Same callId ⇒ same CallKit UUID, so this tears
    // down the ring already showing from the 'incoming_call' push (and, if the
    // ring push never arrived, briefly reports-then-ends a call that was already
    // over — the correct, penalty-free way to satisfy the deadline).
    if pushType == "call_cancel" {
      let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance
      plugin?.showCallkitIncoming(data, fromPushKit: true) {
        plugin?.endCall(data)
        completion()
      }
      return
    }

    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true)
    completion()
  }

  // MARK: - CallkitIncomingAppDelegate (WebRTC audio session handoff)
  //
  // The plugin calls these on us *because* we conform to the protocol. The
  // crucial pair is didActivate/didDeactivateAudioSession: we hand CallKit's
  // audio session to WebRTC so the microphone is actually captured. Without
  // it, output worked (received audio played) but our mic published silence.
  //
  // IMPORTANT: once we conform, the plugin delegates CXAction fulfillment to
  // us (it only fulfills itself when there's no CallkitIncomingAppDelegate).
  // So onAccept/onDecline/onEnd MUST call action.fulfill() or CallKit hangs.

  public func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    action.fulfill()
  }

  public func onDecline(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  public func onEnd(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  public func onTimeOut(_ call: Call) {}

  public func didActivateAudioSession(_ audioSession: AVAudioSession) {
    let rtcSession = RTCAudioSession.sharedInstance()
    rtcSession.audioSessionDidActivate(audioSession)
    rtcSession.isAudioEnabled = true
  }

  public func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    let rtcSession = RTCAudioSession.sharedInstance()
    rtcSession.audioSessionDidDeactivate(audioSession)
    rtcSession.isAudioEnabled = false
  }

  public func providerDidReset() {}
}
