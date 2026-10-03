import SwiftUI

@main struct GitZipperApp: App {
    @StateObject var gh = GH()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(gh)
                .preferredColorScheme(.dark).tint(.white)
        }
    }
}
