import Foundation
import NtfyKit

/// Runs ntfy action buttons. HTTP actions go to arbitrary URLs, so they never carry server credentials.
@MainActor
enum ActionPerformer {
    static func perform(_ action: Action) async {
        switch action.kind {
        case .view:
            if let url = action.url.flatMap(URL.init(string:)) { await Platform.open(url) }
        case .http:
            guard let url = action.url.flatMap(URL.init(string:)) else { return }
            try? await NtfyClient(baseURL: url).perform(action)
        case .copy:
            action.value.map(Platform.copy)
        case .broadcast, nil:
            break
        }
    }
}
