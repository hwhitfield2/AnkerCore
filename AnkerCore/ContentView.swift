import SwiftUI

struct ContentView: View {
    @StateObject private var probe = BluetoothProbe()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                RelayPalette.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        brandHeader
                        recorderHero
                        tasksCard
                        connectionCard
                        pipelineCard
                        recordingsCard
                        nearbyDevicesCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingSettings) {
                SettingsView(probe: probe)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(RelayPalette.background)
            }
        }
        .tint(RelayPalette.coral)
        .preferredColorScheme(.dark)
        .task { probe.refreshTasks() }
    }

    private var brandHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ANKERCORE")
                    .font(.caption2.weight(.black))
                    .tracking(2.4)
                    .foregroundStyle(RelayPalette.mint)
                Text("Relay")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(RelayPalette.surface, in: Circle())
                    .overlay(Circle().stroke(RelayPalette.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Settings and diagnostics")
        }
        .padding(.top, 10)
    }

    private var recorderHero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [heroColor.opacity(0.32), heroColor.opacity(0.04)], center: .center, startRadius: 1, endRadius: 86))
                    .frame(width: 174, height: 174)
                Circle()
                    .stroke(heroColor.opacity(0.32), lineWidth: 1)
                    .frame(width: 132, height: 132)
                Image(systemName: probe.recorderState == "Recording" ? "waveform" : "waveform.badge.mic")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(heroColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: probe.recorderState == "Recording")
            }

            VStack(spacing: 6) {
                Text(heroTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(RelayPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                StatusPill(
                    icon: probe.connectedPeripheralID == nil ? "bolt.slash.fill" : "bolt.fill",
                    title: probe.connectedPeripheralID == nil ? "Disconnected" : "Connected",
                    color: probe.connectedPeripheralID == nil ? RelayPalette.secondaryText : RelayPalette.mint
                )
                StatusPill(
                    icon: probe.uploadConfigured ? "cloud.fill" : "iphone",
                    title: probe.uploadConfigured ? "Cloud ready" : "Local only",
                    color: probe.uploadConfigured ? RelayPalette.sky : RelayPalette.secondaryText
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 25)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(colors: [RelayPalette.surfaceRaised, RelayPalette.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(RelayPalette.stroke, lineWidth: 1))
    }

    private var connectionCard: some View {
        RelayCard(title: "Recorder", icon: "dot.radiowaves.left.and.right") {
            if let connectedID = probe.connectedPeripheralID {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(RelayPalette.mint.opacity(0.14)).frame(width: 46, height: 46)
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(RelayPalette.mint)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Soundcore Work").font(.headline)
                        Text("ID \(connectedID.uuidString.prefix(8)) · ready for button events")
                            .font(.caption)
                            .foregroundStyle(RelayPalette.secondaryText)
                    }
                    Spacer()
                    Button("Disconnect") { probe.disconnect() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelayPalette.secondaryText)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(probe.isScanning ? "Looking for your recorder…" : "Open the case, then scan nearby.")
                        .font(.subheadline)
                        .foregroundStyle(RelayPalette.secondaryText)
                    Button {
                        probe.isScanning ? probe.stopScanning() : probe.startScanning()
                    } label: {
                        Label(probe.isScanning ? "Stop scanning" : "Find Soundcore Work", systemImage: probe.isScanning ? "stop.fill" : "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(!probe.canScan)
                }
            }
        }
    }

    private var tasksCard: some View {
        RelayCard(title: "My tasks", icon: "checklist") {
            VStack(spacing: 11) {
                HStack {
                    Text(probe.tasksState)
                        .font(.caption)
                        .foregroundStyle(RelayPalette.secondaryText)
                        .lineLimit(2)
                    Spacer()
                    Button { probe.refreshTasks() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(probe.tasksLoading ? 180 : 0))
                    }
                    .disabled(!probe.uploadConfigured || probe.tasksLoading)
                }

                if probe.openTasks.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(RelayPalette.mint)
                        Text(probe.uploadConfigured ? "New action items will collect here." : "Connect the private route in Settings to see your running list.")
                            .font(.subheadline)
                            .foregroundStyle(RelayPalette.secondaryText)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                } else {
                    ForEach(Array(probe.openTasks.prefix(12).enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider().overlay(RelayPalette.stroke) }
                        TaskRow(task: task, isBusy: probe.tasksLoading) { probe.completeTask(task) }
                    }
                }
            }
        }
    }

    private var pipelineCard: some View {
        RelayCard(title: "Automatic flow", icon: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 0) {
                PipelineStep(icon: "arrow.down.circle.fill", title: "Fetch recording", detail: probe.transferState, color: transferColor, showsLine: true)
                PipelineStep(
                    icon: "waveform.badge.magnifyingglass",
                    title: "Transcribe & sort · \(probe.processingMode)",
                    detail: probe.uploadConfigured ? probe.uploadState : "Add your private token to enable automatic routing",
                    color: probe.uploadConfigured ? RelayPalette.sky : RelayPalette.secondaryText,
                    showsLine: false
                )

                if probe.transferProgress > 0, probe.transferProgress < 1 {
                    ProgressView(value: probe.transferProgress)
                        .tint(RelayPalette.coral)
                        .padding(.top, 12)
                }

                if let destination = probe.lastDestinationURL {
                    Link(destination: destination) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Open latest item in Notion")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RelayPalette.mint)
                        .padding(14)
                        .background(RelayPalette.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .padding(.top, 14)
                }
            }
        }
    }

    private var recordingsCard: some View {
        RelayCard(title: "Recordings", icon: "waveform") {
            VStack(spacing: 12) {
                HStack {
                    Text(probe.recordingListState)
                        .font(.caption)
                        .foregroundStyle(RelayPalette.secondaryText)
                    Spacer()
                    Button { probe.loadRecordings() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .disabled(!probe.canLoadRecordings)
                }

                if probe.recordings.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.slash")
                            .font(.title3)
                            .foregroundStyle(RelayPalette.secondaryText)
                        Text("Recordings will appear here after connecting.")
                            .font(.subheadline)
                            .foregroundStyle(RelayPalette.secondaryText)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(Array(probe.recordings.prefix(6).enumerated()), id: \.element.id) { index, recording in
                        if index > 0 { Divider().overlay(RelayPalette.stroke) }
                        RecordingRow(probe: probe, recording: recording)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nearbyDevicesCard: some View {
        if probe.connectedPeripheralID == nil, !probe.devices.isEmpty {
            RelayCard(title: "Nearby", icon: "sensor.tag.radiowaves.forward") {
                VStack(spacing: 10) {
                    ForEach(probe.devices) { device in
                        DeviceRow(device: device) { probe.connect(to: device.id) }
                    }
                }
            }
        }
    }

    private var heroColor: Color {
        switch probe.recorderState {
        case "Recording": RelayPalette.coral
        case "Paused": RelayPalette.amber
        case "Stopped": RelayPalette.mint
        default: RelayPalette.sky
        }
    }

    private var heroTitle: String {
        switch probe.recorderState {
        case "Recording": "Recording now"
        case "Paused": "Recording paused"
        case "Stopped": "Captured"
        default: probe.connectedPeripheralID == nil ? "Ready when you are" : "Listening for the button"
        }
    }

    private var heroSubtitle: String {
        if probe.recorderState == "Stopped", let duration = probe.lastRecordingDuration {
            return "\(duration)-second recording · fetching automatically"
        }
        if probe.recorderState == "Recording" { return "Press the recorder button again when you’re done." }
        if probe.connectedPeripheralID == nil { return "Connect once. After that, the recorder button runs the whole flow." }
        return "Press the physical recorder button to begin."
    }

    private var transferColor: Color {
        if probe.transferState.localizedCaseInsensitiveContains("failed") { return RelayPalette.coral }
        if probe.transferProgress > 0, probe.transferProgress < 1 { return RelayPalette.amber }
        if probe.transferProgress >= 1 { return RelayPalette.mint }
        return RelayPalette.secondaryText
    }
}

private struct RelayCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RelayPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(RelayPalette.stroke, lineWidth: 1))
    }
}

private struct StatusPill: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: Capsule())
    }
}

private struct PipelineStep: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color
    let showsLine: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                if showsLine {
                    Rectangle().fill(RelayPalette.stroke).frame(width: 1, height: 34)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RelayPalette.secondaryText)
                    .lineLimit(2)
            }
            .padding(.top, 5)
            Spacer()
        }
    }
}

private struct RecordingRow: View {
    @ObservedObject var probe: BluetoothProbe
    let recording: RecordingMetadata
    @State private var showingEnrollment = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: probe.downloadedRecordings[recording.id] == nil ? "waveform.circle" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(probe.downloadedRecordings[recording.id] == nil ? RelayPalette.sky : RelayPalette.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.subheadline.weight(.semibold))
                Text(ByteCountFormatter.string(fromByteCount: Int64(recording.sizeBytes), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(RelayPalette.secondaryText)
            }
            Spacer()
            if let url = probe.downloadedRecordings[recording.id] {
                HStack(spacing: 5) {
                    Button { showingEnrollment = true } label: {
                        Image(systemName: "person.wave.2.fill")
                            .frame(width: 36, height: 36)
                            .background(RelayPalette.surfaceRaised, in: Circle())
                    }
                    .accessibilityLabel("Enroll a voice from this recording")
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                            .background(RelayPalette.surfaceRaised, in: Circle())
                    }
                }
            } else {
                Button("Fetch") { probe.fetchRecording(recording) }
                    .font(.caption.weight(.bold))
                    .disabled(!probe.canFetchRecording)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showingEnrollment) {
            VoiceEnrollmentView(probe: probe, recording: recording)
                .presentationDragIndicator(.visible)
                .presentationBackground(RelayPalette.background)
        }
    }
}

private struct VoiceEnrollmentView: View {
    @ObservedObject var probe: BluetoothProbe
    let recording: RecordingMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var consentConfirmed = false
    @State private var isEnrolling = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Clean voice sample") {
                    TextField("Speaker name", text: $name)
                    Text("Use a recording containing at least five seconds of only this person. Background speech reduces accuracy.")
                        .font(.caption)
                        .foregroundStyle(RelayPalette.secondaryText)
                }
                Section("Consent") {
                    Toggle("This person consented to voice identification", isOn: $consentConfirmed)
                    Text("The mathematical voice signature stays on this iPhone and can be deleted. A recognized name becomes a transcript label and follows your configured Notion/cloud route.")
                        .font(.caption)
                        .foregroundStyle(RelayPalette.secondaryText)
                }
                if let error { Section { Text(error).foregroundStyle(RelayPalette.coral) } }
                Section {
                    Button {
                        isEnrolling = true
                        Task {
                            error = await probe.enrollVoice(name: name, recording: recording, consentConfirmed: consentConfirmed)
                            isEnrolling = false
                            if error == nil { dismiss() }
                        }
                    } label: {
                        HStack {
                            if isEnrolling { ProgressView().padding(.trailing, 5) }
                            Text(isEnrolling ? "Creating voice signature…" : "Enroll voice")
                        }
                    }
                    .disabled(isEnrolling || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !consentConfirmed)
                }
            }
            .scrollContentBackground(.hidden)
            .background(RelayPalette.background)
            .navigationTitle("Voice identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(RelayPalette.coral)
    }
}

private struct TaskRow: View {
    let task: AnkerCoreTask
    let isBusy: Bool
    let onComplete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(priorityColor)
            }
            .disabled(isBusy)
            .accessibilityLabel("Complete \(task.title)")

            Link(destination: task.url) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 7) {
                        Text(task.priority)
                            .foregroundStyle(priorityColor)
                        if let date = task.dueDate {
                            Text("·")
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .foregroundStyle(date < Calendar.current.startOfDay(for: Date()) ? RelayPalette.coral : RelayPalette.secondaryText)
                        }
                        if !task.owner.isEmpty {
                            Text("· \(task.owner)")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(RelayPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private var priorityColor: Color {
        switch task.priority {
        case "Urgent": RelayPalette.coral
        case "High": RelayPalette.amber
        case "Low": RelayPalette.secondaryText
        default: RelayPalette.sky
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(RelayPalette.coral)
                    .frame(width: 42, height: 42)
                    .background(RelayPalette.coral.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("Signal \(device.rssi) dBm").font(.caption).foregroundStyle(RelayPalette.secondaryText)
                }
                Spacer()
                Text("Connect").font(.caption.weight(.bold)).foregroundStyle(RelayPalette.coral)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(RelayPalette.coral)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsView: View {
    @ObservedObject var probe: BluetoothProbe
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = AnkerCoreUploadClient.savedEndpoint
    @State private var webhookURL = AnkerCoreUploadClient.savedWebhookURL
    @State private var uploadToken = ""
    @State private var configurationError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: probe.uploadConfigured ? "lock.shield.fill" : "lock.slash")
                            .font(.title2)
                            .foregroundStyle(probe.uploadConfigured ? RelayPalette.mint : RelayPalette.amber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(probe.uploadConfigured ? "Private route connected" : "Cloud routing is off").font(.headline)
                            Text(probe.uploadState).font(.caption).foregroundStyle(RelayPalette.secondaryText)
                        }
                    }
                }

                Section("Cloud connection") {
                    TextField("Service URL", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(probe.uploadConfigured ? "Paste replacement token" : "Paste private token", text: $uploadToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let configurationError {
                        Text(configurationError).font(.caption).foregroundStyle(RelayPalette.coral)
                    }
                    Button("Save private connection") {
                        configurationError = probe.saveUploadConfiguration(
                            endpoint: endpoint,
                            token: uploadToken,
                            webhookURL: webhookURL
                        )
                        if configurationError == nil { uploadToken = "" }
                    }
                    if probe.uploadConfigured {
                        Button("Remove private token", role: .destructive) {
                            probe.clearUploadToken()
                            uploadToken = ""
                        }
                    }
                }

                Section("Optional webhook") {
                    TextField("https://your-service.example/webhook", text: $webhookURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("After Notion routing, the service sends the transcript and destination metadata here. Leave blank to disable.")
                        .font(.caption)
                        .foregroundStyle(RelayPalette.secondaryText)
                }

                Section("Voice identities · on this iPhone") {
                    if probe.voiceProfiles.isEmpty {
                        Text("Fetch a clean solo recording, then tap the people-and-wave icon beside it to enroll a consenting speaker.")
                            .font(.caption)
                            .foregroundStyle(RelayPalette.secondaryText)
                    } else {
                        ForEach(probe.voiceProfiles) { profile in
                            HStack {
                                Label(profile.name, systemImage: "person.wave.2.fill")
                                Spacer()
                                Button(role: .destructive) { probe.deleteVoiceProfile(profile) } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Delete voice profile for \(profile.name)")
                            }
                        }
                    }
                    Text(probe.voiceIdentityState)
                        .font(.caption)
                        .foregroundStyle(RelayPalette.secondaryText)
                }

                Section("Privacy") {
                    Label("Token protected by iPhone Keychain", systemImage: "key.fill")
                    Label("Audio stays on iPhone when local speech succeeds", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    Label("Cloud receives text only when local sorting needs help", systemImage: "text.badge.checkmark")
                    Label("Raw audio uses cloud only as a transcription fallback", systemImage: "icloud.and.arrow.up")
                    Label("No audio or keys in diagnostic logs", systemImage: "eye.slash.fill")
                    Label("Voice signatures stay on this iPhone and are excluded from backup", systemImage: "person.badge.shield.checkmark.fill")
                    Label("Unknown or uncertain voices keep generic Speaker labels", systemImage: "questionmark.circle.fill")
                }

                Section("Diagnostics") {
                    LabeledContent("Bluetooth", value: probe.bluetoothState)
                    LabeledContent("Connection", value: probe.connectionState)
                    LabeledContent("Recorder", value: probe.recorderState)
                    LabeledContent("Characteristics", value: String(probe.characteristics.count))
                    Button("Start fresh diagnostic capture") { probe.startNewCapture() }
                    ShareLink(item: probe.captureURL) {
                        Label("Share diagnostic capture", systemImage: "square.and.arrow.up")
                    }
                }

                if !probe.events.isEmpty {
                    Section("Latest events") {
                        ForEach(probe.events.prefix(12)) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.kind.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(RelayPalette.mint)
                                    Spacer()
                                    Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(RelayPalette.secondaryText)
                                }
                                Text(event.summary).font(.caption)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RelayPalette.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(RelayPalette.coral)
    }
}

private struct RelayPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(RelayPalette.background)
            .padding(.vertical, 13)
            .background(
                LinearGradient(colors: [RelayPalette.coral, RelayPalette.coralLight], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private enum RelayPalette {
    static let background = Color(red: 0.035, green: 0.065, blue: 0.075)
    static let surface = Color(red: 0.075, green: 0.115, blue: 0.125)
    static let surfaceRaised = Color(red: 0.105, green: 0.155, blue: 0.165)
    static let stroke = Color.white.opacity(0.075)
    static let secondaryText = Color(red: 0.59, green: 0.66, blue: 0.67)
    static let coral = Color(red: 1.0, green: 0.38, blue: 0.28)
    static let coralLight = Color(red: 1.0, green: 0.55, blue: 0.37)
    static let mint = Color(red: 0.37, green: 0.91, blue: 0.68)
    static let sky = Color(red: 0.38, green: 0.73, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
}
