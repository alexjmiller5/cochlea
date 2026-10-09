import Network
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Links the app handles, under the `cochlea` scheme and the legacy `offlineshazam` one.
enum DeepLink: Equatable {
    case enroll, capture

    init?(_ url: URL) {
        guard ["cochlea", "offlineshazam"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        switch url.host?.lowercased() {
        case "enroll": self = .enroll
        case "capture": self = .capture
        default: return nil
        }
    }
}

@MainActor
enum Runtime {
    static let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "cochlea") + ".delivery"
    static let connection = ConnectionStore()
    /// Posted after an enrollment link saves a connection.
    static let connectionChanged = Notification.Name("CochleaConnectionChanged")
    static let notifications = CaptureNotifications()
    #if os(iOS)
    nonisolated static let deviceName = "iPhone"
    #else
    nonisolated static let deviceName = "Mac"
    #endif
    static let controller: Result<CaptureController, Error> = Result {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = try CaptureStore.applicationDirectory(in: root)
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

    static func open(_ url: URL) {
        switch DeepLink(url) {
        case .enroll: enroll(url)
        case .capture:
            guard case .success(let controller) = controller else { return }
            Task { await controller.startCapture() }
        case nil: break
        }
    }

    /// An enrollment link (`offlineshazam://enroll?url=&token=`, opened from
    /// Music Sync's enrollment page): save the connection like Settings does,
    /// say so, and send whatever was waiting.
    @MainActor
    static func enroll(_ link: URL) {
        guard case .success(let controller) = controller,
              let configuration = try? DeliveryConfiguration.fromEnrollLink(link),
              (try? connection.save(configuration)) != nil else { return }
        NotificationCenter.default.post(name: connectionChanged, object: nil)
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
        monitor.start(queue: DispatchQueue(label: "cochlea.connectivity"))
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

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(Runtime.open) }
    #endif
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {}
#else
extension AppDelegate: NSApplicationDelegate {}
#endif
