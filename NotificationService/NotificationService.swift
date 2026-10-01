import UserNotifications
import NtfyKit

/// Formats each push before display: resolves poll requests against the server, adds emoji, priority,
/// action buttons and image attachments, and hands the message to the app through the inbox.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent,
              let payload = PushPayload(userInfo: request.content.userInfo)
        else {
            contentHandler(request.content)
            return
        }
        bestAttempt = mutable
        // Only this task mutates the content until it delivers or the system expires the extension
        nonisolated(unsafe) let content = mutable
        work = Task {
            if let message = await resolve(payload) {
                NotificationFormatter.apply(message, baseURL: payload.baseURL, to: content)
                try? Inbox().deposit(message, baseURL: payload.baseURL)
                content.categoryIdentifier = await NotificationCategories.register(for: message)
                if let attachment = await imageAttachment(for: message, baseURL: payload.baseURL) {
                    content.attachments = [attachment]
                }
            }
            deliver(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        if let bestAttempt { deliver(bestAttempt) }
    }

    private func deliver(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }

    private func resolve(_ payload: PushPayload) async -> Message? {
        guard payload.needsFetch else { return payload.message }
        let client = NtfyClient(baseURL: payload.baseURL, credential: CredentialStore().credential(for: payload.baseURL))
        return try? await client.message(topic: payload.message.topic, id: payload.messageID)
    }

    private func imageAttachment(for message: Message, baseURL: URL) async -> UNNotificationAttachment? {
        guard let attachment = message.attachment, attachment.isImage, !attachment.isExpired,
              let url = URL(string: attachment.url)
        else { return nil }
        var request = URLRequest(url: url)
        if url.host() == baseURL.host(), let credential = CredentialStore().credential(for: baseURL) {
            request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(URL(filePath: attachment.name).pathExtension.isEmpty ? "jpg" : URL(filePath: attachment.name).pathExtension)
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: message.id, url: file)
    }
}
