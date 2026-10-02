import Network
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
enum Runtime {
    static let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "offline-shazam") + ".delivery"
    static let connection = ConnectionStore()
    static let notifications = CaptureNotifications()
    #if os(iOS)
    static let deviceName = "iPhone"
    #else
    static let deviceName = "Mac"
    #endif
    static let controller: Result<CaptureController, Error> = Result {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("offline-shazam", isDirectory: true)
        let store = try CaptureStore(directory: directory)
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        let delivery = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
                                       connection: { try connection.load() }, sessionConfiguration: configuration)
        let recorder = AudioRecorder()
        let controller = CaptureController(store: store, delivery: delivery,
                                           recordAudio: { try await recorder.capture() },
                                           recognize: { try await ShazamMatcher().match($0) },
                                           recordingActivity: RecordingActivity())
        controller.onRecordsChanged = { await notifications.reconcile(store: store) }
        delivery.onRecordsChanged = { await notifications.reconcile(store: store) }
        return controller
    }

    /// An enrollment link (`offlineshazam://enroll?url=&token=`, opened from
    /// Music Sync's enrollment page): save the connection like Settings does,
    /// say so, and send whatever was waiting.
    @MainActor
    static func enroll(_ link: URL) {
        guard case .success(let controller) = controller,
              let configuration = try? DeliveryConfiguration.fromEnrollLink(link),
              (try? connection.save(configuration)) != nil else { return }
        Task {
            try? await controller.delivery.connectionChanged()
            let verified = await controller.delivery.verifyConnection()
            let content = UNMutableNotificationContent()
            content.title = verified ? "Connected to Music Sync" : "Music Sync connection saved"
            content.body = verified ? "Waiting songs are sending automatically."
                : (controller.delivery.connectionIssue ?? "Songs will retry automatically.")
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            await controller.resume()
        }
    }

    // Reconnecting resumes queued work while the app is running.
    static func startConnectivityMonitor(_ monitor: NWPathMonitor) {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let controller = try? Runtime.controller.get() else { return }
                let reconnected = !controller.isOnline && online
                controller.isOnline = online
                if reconnected { await controller.resume() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "offline-shazam.connectivity"))
    }
}

@MainActor
final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let monitor = NWPathMonitor()

    private func start() {
        UNUserNotificationCenter.current().delegate = self
        _ = try? Runtime.controller.get().delivery.session
        Runtime.startConnectivityMonitor(monitor)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    #if os(iOS)
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        start()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Runtime.backgroundIdentifier, let controller = try? Runtime.controller.get() else {
            completionHandler()
            return
        }
        controller.delivery.backgroundCompletion = completionHandler
        _ = controller.delivery.session
    }
    #else
    func applicationDidFinishLaunching(_ notification: Notification) { start() }
    #endif
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {}
#else
extension AppDelegate: NSApplicationDelegate {}
#endif
