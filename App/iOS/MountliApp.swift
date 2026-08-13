import SwiftUI

@main
struct MountliMobileApp: App {
    @State private var model = MountliAppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
                .onOpenURL(perform: model.handleRecoveryURL)
        }
        .backgroundTask(.appRefresh("ch.benavo.mountli.refresh")) {
            await model.performBackgroundRefresh()
        }
    }
}
