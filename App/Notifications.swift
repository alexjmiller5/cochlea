import UserNotifications

@MainActor
final class CaptureNotifications {
    private let center: UNUserNotificationCenter
    private let authorization: () async -> UNAuthorizationStatus
    private let schedule: (UNNotificationRequest) async throws -> Void
    private let existingRequests: () async -> (pending: [UNNotificationRequest], delivered: [UNNotificationRequest])
    private var reconciliation: Task<Void, Never>?

    init(center: UNUserNotificationCenter = .current(),
         authorization: (() async -> UNAuthorizationStatus)? = nil,
         schedule: ((UNNotificationRequest) async throws -> Void)? = nil,
         existingRequests: (() async -> (pending: [UNNotificationRequest], delivered: [UNNotificationRequest]))? = nil) {
        self.center = center
        self.authorization = authorization ?? { await center.notificationSettings().authorizationStatus }
        self.schedule = schedule ?? { try await center.add($0) }
        self.existingRequests = existingRequests ?? {
            let pending = await center.pendingNotificationRequests()
            return (pending, await center.deliveredNotifications().map(\.request))
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func reconcile(store: CaptureStore) async {
        let previous = reconciliation
        let current = Task { @MainActor in
            await previous?.value
            await update(store: store)
        }
        reconciliation = current
        await current.value
    }

    private func update(store: CaptureStore) async {
        switch await authorization() {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let (pending, delivered) = await existingRequests()
        guard let records = try? store.records() else { return }
        for record in records where record.state == .matched || record.state == .accepted || record.state == .delivered {
            let identifier = "capture." + record.id.uuidString
            let legacyPending = pending.contains {
                $0.identifier == identifier && $0.content.userInfo["stage"] as? String == "delivered"
            }
            let existing = (pending.filter { $0.content.userInfo["stage"] as? String != "delivered" } + delivered)
                .filter { $0.identifier == identifier }
            guard record.awaitsSpotify || record.notificationEligible || !existing.isEmpty || legacyPending,
                  let metadata = record.metadata else { continue }
            do {
                // The old combined card may have replaced recognition before either
                // fired. Replace that first alert, but never replay earlier recognition
                // merely because the user dismissed it from Notification Center.
                if legacyPending, !delivered.contains(where: { $0.identifier == identifier }),
                   record.recognitionNotificationDate.map({ $0 > Date() }) ?? true {
                    record.deliveryNotificationScheduled = false
                    record.recognitionNotificationDate = nil
                }
                // Recover an OS-accepted request if the process stopped before SwiftData saved it.
                for request in existing {
                    if request.content.userInfo["stage"] as? String == "delivered" {
                        record.deliveryNotificationScheduled = true
                    } else if record.recognitionNotificationDate == nil,
                              let timestamp = request.content.userInfo["recognitionDate"] as? Double {
                        record.recognitionNotificationDate = Date(timeIntervalSince1970: timestamp)
                    }
                }
                if store.context.hasChanges { try store.save() }
                // Persist any first-alert recovery before canceling the legacy request,
                // so a scheduling failure or relaunch can still retry recognition.
                if legacyPending { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
                guard !record.deliveryNotificationScheduled else { continue }
                guard record.recognitionNotificationDate == nil else { continue }
                let recognitionDate = Date().addingTimeInterval(1)
                let content = UNMutableNotificationContent()
                content.title = "Song recognized"
                content.body = metadata.title + " by " + metadata.artist
                content.sound = .default
                content.interruptionLevel = .active
                content.userInfo = ["captureID": record.id.uuidString,
                                    "stage": "recognized",
                                    "recognitionDate": recognitionDate.timeIntervalSince1970]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                try await schedule(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                record.notificationEligible = true
                record.recognitionNotificationDate = recognitionDate
                try store.save()
            } catch {
                // Notification failure is optional; the next reconciliation retries without changing the song queue.
            }
        }
        for record in records {
            await updateSpotifyFailure(record, store: store, existing: pending + delivered)
        }
    }

    private func updateSpotifyFailure(_ record: CaptureRecord, store: CaptureStore,
                                      existing: [UNNotificationRequest]) async {
        let identifier = "capture.spotify-failure." + record.id.uuidString
        // A queued 202 carries no not_added proof; Music Sync's later no-match does.
        guard record.awaitsSpotify, record.spotifyOutcome == .notAdded,
              let metadata = record.metadata else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }
        do {
            if record.spotifyFailureNotificationDate == nil,
               existing.contains(where: { $0.identifier == identifier }) {
                record.spotifyFailureNotificationDate = Date()
                try store.save()
            }
            guard record.spotifyFailureNotificationDate == nil else { return }
            let content = UNMutableNotificationContent()
            content.title = "Couldn't add to Spotify"
            content.body = metadata.title + " by " + metadata.artist +
                ". Saved for retry. Open Cochlea to check delivery."
            content.sound = .default
            content.interruptionLevel = .active
            content.userInfo = ["captureID": record.id.uuidString, "stage": "spotify_not_added"]
            try await schedule(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            // A retry may have advanced while the OS accepted the request.
            if record.spotifyOutcome != .notAdded {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            }
            record.spotifyFailureNotificationDate = Date()
            try store.save()
        } catch {
            // Keep the capture queued; reconciliation can retry notification scheduling.
        }
    }

}
