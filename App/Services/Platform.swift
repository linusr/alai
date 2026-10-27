import SwiftUI
import NtfyKit
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// The few system services whose APIs differ between iOS and macOS.
@MainActor
enum Platform {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    /// This app's page in the system notification settings.
    static var notificationSettingsURL: URL {
        #if canImport(UIKit)
        URL(string: UIApplication.openNotificationSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
        #endif
    }

    /// Opens a URL from a message. Anyone who can publish to a topic chooses these, so local files never
    /// open, and on Mac, where any registered scheme launches its app without asking, only web, mail,
    /// phone, message and Alai links do.
    static func open(_ url: URL) async {
        guard let scheme = url.scheme?.lowercased(), scheme != "file" else { return }
        #if canImport(UIKit)
        await UIApplication.shared.open(url)
        #else
        guard ["http", "https", "mailto", "tel", "sms", TopicStyle.linkScheme].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension View {
    /// The model, its services and the SwiftData container every app view reads from the environment.
    func appEnvironment(_ model: AppModel) -> some View {
        environment(model)
            .environment(model.servers)
            .environment(model.push)
            .environment(model.router)
            .modelContainer(model.container)
    }
}

extension View {
    /// A compact navigation title on iPhone; Mac windows have no large titles.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Text entry for identifiers such as topic names, which must not be capitalized or corrected.
    func identifierEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// Text entry for a server URL.
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the iPhone navigation bar; the Mac window toolbar.
    static var trailingAction: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

extension Color {
    /// The backdrop behind grouped cards: the grouped table background on iPhone, the window on Mac.
    static var groupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
