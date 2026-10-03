import SwiftUI

struct ContentView: View {
    @Bindable var controller: CaptureController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var error: String?
    private let blue = Color(red: 8 / 255, green: 123 / 255, blue: 193 / 255)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Text("Keep the song.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Even without a connection.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    if let issue = controller.connectionIssue {
                        Button { showingSettings = true } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image("AlertCircle").resizable().frame(width: 24, height: 24).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Spotify delivery needs attention").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        if controller.isRecording {
                            controller.cancelCapture()
                            error = nil
                            return
                        }
                        Task {
                            do { _ = try await controller.capture(); error = nil }
                            catch is CancellationError { error = nil }
                            catch let captureError as CaptureError { error = captureError.localizedDescription }
                            catch { self.error = "Could not save this capture. Please try again." }
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image("Waveform").resizable().scaledToFit().frame(width: 76, height: 76)
                            Text(controller.isRecording ? "Cancel capture" : "Capture song")
                                .font(.title3.weight(.semibold))
                            Text(controller.isRecording
                                 ? (controller.isOnline ? "Listening for a Shazam match" : "Saving an offline capture")
                                 : "Tap to identify music")
                                .font(.footnote)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 224)
                        .background(blue.gradient, in: RoundedRectangle(cornerRadius: 36))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.isRecording ? "Cancel capture" : "Capture song")
                    .accessibilityValue(controller.isRecording ? "Listening" : "Ready")

                    VStack(spacing: 8) {
                        if let error {
                            Text(error).foregroundStyle(.red)
                        } else if controller.isRecording {
                            Text(controller.isOnline ? "Identifying the music around you." : "Saving the music for identification when online.")
                        } else if controller.isProcessing {
                            HStack(spacing: 8) { ProgressView(); Text("Identifying saved captures…") }
                        } else if let status = controller.status {
                            Text(status)
                        } else {
                            Text("Identify music now. Offline captures are handled automatically on your next online use.")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 42)

                    if !controller.records.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text("Your captures").font(.title2.bold())
                                Spacer()
                                let pending = controller.records.filter { $0.state == .pending || $0.state == .matched }.count
                                if pending > 0 { Text("\(pending) pending").font(.caption).foregroundStyle(.secondary) }
                            }
                            ForEach(controller.records.reversed()) { record in
                                CaptureRow(record: record,
                                           isUploading: controller.uploadingIDs.contains(record.id),
                                           connectionIssue: controller.connectionIssue,
                                           isOnline: controller.isOnline)
                                if record.id != controller.records.first?.id { Divider() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 32)
            }
            .background(Platform.groupedBackground)
            .navigationTitle("Offline Shazam")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: Platform.trailing) {
                    Button("Settings") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(controller: controller) }
            .task {
                controller.refresh()
                _ = await Runtime.notifications.requestAuthorization()
                await resumeAfterActivation()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await resumeAfterActivation() } }
            }
        }
        .tint(blue)
    }

    private func resumeAfterActivation() async {
        // Give a foreground capture intent time to start its microphone first.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        await controller.resume()
    }
}

private struct CaptureRow: View {
    let record: CaptureRecord
    let isUploading: Bool
    let connectionIssue: String?
    let isOnline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title ?? "Saved capture").font(.headline)
            if let artist = record.artist { Text(artist).foregroundStyle(.secondary) }
            HStack {
                HStack(spacing: 6) {
                    if record.state == .matched, isUploading, connectionIssue == nil {
                        ProgressView().controlSize(.mini).tint(color)
                    } else {
                        Image(icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(label).fontWeight(.medium)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(color.opacity(0.1), in: Capsule())
                Spacer()
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            if let message = record.lastError, !isUploading {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch record.state {
        case .pending: return "Saved for identification"
        case .matched:
            if !isOnline { return "Waiting for internet" }
            if connectionIssue != nil { return "Check Music Sync" }
            if isUploading { return isOnline ? "Sending to Spotify…" : "Waiting for internet" }
            return record.nextAttemptAt == nil ? "Queued for Spotify" : "Will retry automatically"
        case .delivered: return "Added to Spotify"
        case .unmatched: return "Not identified"
        }
    }

    private var color: Color {
        if record.state == .delivered { return .green }
        if record.state == .matched {
            return connectionIssue == nil ? .blue : .orange
        }
        return .secondary
    }

    private var icon: String {
        if record.state == .delivered { return "CircleCheck" }
        if record.state == .unmatched || (record.state == .matched && connectionIssue != nil) { return "AlertCircle" }
        return "Clock"
    }
}

private struct SettingsView: View {
    let controller: CaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var connection: DeliveryConfiguration?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let connection {
                        HStack(spacing: 8) {
                            Image("CircleCheck").resizable().frame(width: 18, height: 18)
                            Text("Connected to \(connection.endpoint.host ?? "Music Sync")")
                        }
                        .foregroundStyle(Color.green)
                        Button("Disconnect", role: .destructive) { disconnect() }
                    } else {
                        HStack(spacing: 8) {
                            Image("AlertCircle").resizable().frame(width: 18, height: 18)
                            Text("Not connected")
                        }
                        .foregroundStyle(Color.secondary)
                    }
                    if let message { Text(message).font(.footnote) }
                } header: { Text("Music Sync") } footer: {
                    Text(connection == nil
                         ? "Open the enrollment link from Music Sync on this \(Runtime.deviceName) to connect. Songs are kept and sent once connected."
                         : "This \(Runtime.deviceName)'s connection came from its enrollment link and is stored securely on it.")
                }
                Section("Offline captures") {
                    Text("When online, Shazam listens and identifies the song as soon as it can. Offline captures are saved for your next online use. Once identified, delivery can continue in the background.")
                    Text("Failed deliveries retry automatically while the app is running and on your next use. Added to Spotify appears only after Music Sync confirms delivery.")
                    Text("Shazam identifies the music. Music Sync adds it to Spotify.")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings").inlineTitle()
            .toolbar { ToolbarItem(placement: Platform.trailing) { Button("Done") { dismiss() } } }
            .onAppear(perform: reload)
            // An enrollment link opened while Settings is up (Runtime.enroll).
            .onReceive(NotificationCenter.default.publisher(for: Runtime.connectionChanged)) { _ in reload() }
        }
        .sheetChrome { dismiss() }
    }

    private func reload() {
        do {
            connection = try Runtime.connection.load()
            message = connection == nil ? nil : controller.delivery.connectionIssue
        } catch { message = error.localizedDescription }
    }

    private func disconnect() {
        do {
            try Runtime.connection.delete()
            connection = nil
            message = nil
            Task { try? await controller.delivery.connectionChanged() }
        } catch { message = error.localizedDescription }
    }
}

enum Platform {
    #if os(iOS)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let trailing: ToolbarItemPlacement = .topBarTrailing
    #else
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    static let trailing: ToolbarItemPlacement = .primaryAction
    #endif
}

private extension View {
    // macOS sheets take no toolbar and size to content; give Settings a fixed frame and a Done bar.
    @ViewBuilder func sheetChrome(done: @escaping () -> Void) -> some View {
        #if os(macOS)
        frame(width: 460, height: 640)
            .safeAreaInset(edge: .bottom) {
                HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
                    .padding(12).background(.bar)
            }
        #else
        self
        #endif
    }

    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if os(macOS)
struct MenuBarView: View {
    @Bindable var controller: CaptureController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(controller.isRecording ? "Cancel capture" : "Capture song") {
            if controller.isRecording { controller.cancelCapture() }
            else { Task { _ = try? await controller.capture() } }
        }
        .keyboardShortcut("s")
        if let status = controller.status { Text(status) }
        let pending = controller.records.filter { $0.state == .pending || $0.state == .matched }.count
        if pending > 0 { Text("\(pending) pending") }
        Divider()
        Button("Open Offline Shazam") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
