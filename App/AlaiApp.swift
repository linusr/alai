import SwiftUI
import CoreSpotlight

@main
struct AlaiApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .appEnvironment(delegate.model)
                .onOpenURL { url in
                    delegate.model.router.open(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        delegate.model.router.openMessage(key: key)
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let model = delegate.model
            switch phase {
            case .active:
                Task {
                    await model.refreshAll()
                    await model.registerForPush()
                    model.setLiveUpdates(active: true)
                }
            case .background:
                model.setLiveUpdates(active: false)
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
    }
}
