import SwiftUI

@main
struct CochleaApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(iOS)
        mainWindow
        #else
        // Links go to the app delegate; by default SwiftUI opens another window for each one.
        mainWindow.defaultSize(width: 440, height: 720).handlesExternalEvents(matching: [])
        MenuBarExtra("Cochlea", systemImage: "waveform") {
            if case .success(let controller) = Runtime.controller { MenuBarView(controller: controller) }
            else { Text("Captures unavailable") }
        }
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup(id: "main") {
            Group {
                switch Runtime.controller {
                case .success(let controller): ContentView(controller: controller)
                case .failure:
                    ContentUnavailableView("Captures unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text("Unlock your \(Runtime.deviceName) and reopen the app. Existing captures have not been removed."))
                }
            }
            #if os(iOS)
            .onOpenURL { Runtime.open($0) }
            #endif
        }
    }
}
