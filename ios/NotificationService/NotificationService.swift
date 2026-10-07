import Intents
import UserNotifications

/// Rich notifications, Instagram / Snap style : le serveur joint la photo de
/// l'expediteur (`imageUrl`, plus `fcm_options.image`) et active
/// `mutable-content`. Cette extension la telecharge avant l'affichage et la
/// joint a la notification ; sans photo, ou si le telechargement echoue, la
/// notification s'affiche telle quelle (jamais bloquee, jamais perdue).
class NotificationService: UNNotificationServiceExtension {

  /// Style « Communication » (la photo ronde de l'expediteur a la place de
  /// l'icone de l'app, comme iMessage / Snap). Il demande la capacite
  /// « Communication Notifications » sur l'App ID : a n'activer qu'une fois
  /// ajoutee, sinon iOS l'ignore. Desactive : seule la vignette est jointe.
  private static let useCommunicationStyle = false

  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttempt = content

    guard let url = Self.imageURL(from: request.content.userInfo) else {
      contentHandler(content)
      return
    }

    Self.download(url) { [weak self] fileURL, data in
      guard let self = self else { return }
      var result: UNNotificationContent = content

      if Self.useCommunicationStyle, #available(iOS 15.0, *), let data = data,
         let updated = Self.communicationContent(content, avatar: data) {
        result = updated
      } else if let fileURL = fileURL,
                let attachment = try? UNNotificationAttachment(
                  identifier: "avatar", url: fileURL, options: nil) {
        content.attachments = [attachment]
        result = content
      }
      self.contentHandler?(result)
    }
  }

  /// Le systeme nous coupe : on livre ce qu'on a, sans photo plutot que rien.
  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }

  // MARK: - Helpers

  private static func imageURL(from info: [AnyHashable: Any]) -> URL? {
    var raw = info["imageUrl"] as? String
    if raw == nil, let fcm = info["fcm_options"] as? [String: Any] {
      raw = fcm["image"] as? String
    }
    guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          let url = URL(string: s), url.scheme == "https" else { return nil }
    return url
  }

  private static func download(
    _ url: URL,
    completion: @escaping (_ file: URL?, _ data: Data?) -> Void
  ) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    let session = URLSession(configuration: config)
    session.downloadTask(with: url) { tmp, response, error in
      defer { session.finishTasksAndInvalidate() }
      guard error == nil, let tmp = tmp,
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let data = try? Data(contentsOf: tmp), !data.isEmpty,
            data.count < 5_000_000 else {
        completion(nil, nil)
        return
      }
      let ext: String
      switch (response?.mimeType ?? "").lowercased() {
      case "image/png": ext = "png"
      case "image/gif": ext = "gif"
      case "image/webp": ext = "webp"
      default: ext = "jpg"
      }
      let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + "." + ext)
      do {
        try data.write(to: dest)
        completion(dest, data)
      } catch {
        completion(nil, data)
      }
    }.resume()
  }

  /// Notification « Communication » : l'expediteur et sa photo via un
  /// INSendMessageIntent. Renvoie nil si iOS refuse (capacite absente).
  @available(iOS 15.0, *)
  private static func communicationContent(
    _ content: UNMutableNotificationContent,
    avatar: Data
  ) -> UNNotificationContent? {
    let info = content.userInfo
    let senderId = (info["senderId"] as? String) ?? content.threadIdentifier
    let name = content.title
    guard !name.isEmpty else { return nil }
    let handle = INPersonHandle(value: senderId.isEmpty ? name : senderId, type: .unknown)
    let sender = INPerson(
      personHandle: handle,
      nameComponents: nil,
      displayName: name,
      image: INImage(imageData: avatar),
      contactIdentifier: nil,
      customIdentifier: senderId.isEmpty ? nil : senderId
    )
    let intent = INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: content.body,
      speakableGroupName: nil,
      conversationIdentifier: (info["conversationId"] as? String) ?? senderId,
      serviceName: nil,
      sender: sender,
      attachments: nil
    )
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate(completion: nil)
    return try? content.updating(from: intent)
  }
}