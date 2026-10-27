import SwiftUI
import CoreSpotlight

@main
struct AlaiMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MacAppDelegate

    var body: some Scene {
        Window("Alai", id: "main") {
            MacRootView()
                .appEnvironment(delegate.model)
                .onOpenURL { delegate.model.router.open($0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        delegate.model.router.openMessage(key: key)
                    }
                }
        }
        .defaultSize(width: 1000, height: 680)
        .commands { AlaiCommands(model: delegate.model) }

        Settings {
            SettingsView()
                .appEnvironment(delegate.model)
                .frame(width: 520, height: 560)
        }
    }
}

/// Menu bar commands; the matching toolbar buttons live in the main window.
struct AlaiCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Topic…") {
                guard !model.servers.servers.isEmpty else { return }
                model.router.presentedSheet = .newTopic
            }
                .keyboardShortcut("n")
        }
        CommandGroup(before: .windowList) {
            Button("Alai") { openWindow(id: "main") }
                .keyboardShortcut("0")
        }
        CommandMenu("Messages") {
            Button("Refresh") { Task { await model.refreshAll() } }
                .keyboardShortcut("r")
            Button("Mark All as Read") { Task { await model.markAllRead() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
