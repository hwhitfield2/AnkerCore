import Combine
import CoreBluetooth
import Foundation

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var advertisementSummary: String
}

struct CharacteristicSnapshot: Identifiable {
    let id: String
    let serviceUUID: String
    let characteristicUUID: String
    let properties: String
    let isNotifying: Bool
}

struct RecordingMetadata: Identifiable {
    let id: UInt32
    let endTime: UInt32?
    let sizeBytes: UInt32

    var recordedAt: Date { Date(timeIntervalSince1970: TimeInterval(id)) }
}

private struct RecordingListPage {
    let commandType: UInt8
    let fileCount: Int
    let recordings: [RecordingMetadata]
}

struct ProbeEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let kind: String
    let summary: String
    let peripheralID: String?
    let serviceUUID: String?
    let characteristicUUID: String?
    let byteCount: Int?
    let hexPreview: String?
    let valueBase64: String?
}

final class BluetoothProbe: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Starting…"
    @Published private(set) var connectionState = "Not connected"
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var characteristics: [CharacteristicSnapshot] = []
    @Published private(set) var events: [ProbeEvent] = []
    @Published private(set) var connectedPeripheralID: UUID?
    @Published private(set) var captureURL: URL
    @Published private(set) var recorderState = "Waiting for recorder event"
    @Published private(set) var currentRecordingID: UInt32?
    @Published private(set) var lastRecordingDuration: UInt32?
    @Published private(set) var recordings: [RecordingMetadata] = []
    @Published private(set) var recordingListState = "Connect to load recordings"
    @Published private(set) var recordingsLoading = false
    @Published private(set) var transferState = "No audio transfer active"
    @Published private(set) var transferProgress = 0.0
    @Published private(set) var downloadedRecordings: [UInt32: URL] = [:]
    @Published private(set) var uploadState = "Paste the private token once to enable automatic processing"
    @Published private(set) var uploadEndpoint = AnkerCoreUploadClient.savedEndpoint
    @Published private(set) var uploadConfigured = AnkerCoreUploadClient.hasToken
    @Published private(set) var connectionCheckState = "Connection has not been tested"
    @Published private(set) var lastDestinationURL: URL?
    @Published private(set) var processingMode = "On-device preferred"
    @Published private(set) var openTasks: [AnkerCoreTask] = []
    @Published private(set) var tasksState = "Connect your private route to load tasks"
    @Published private(set) var tasksLoading = false
    @Published private(set) var voiceProfiles: [VoiceProfile] = []
    @Published private(set) var voiceIdentityState = "No voice profiles enrolled"
    @Published private(set) var processingLogs = ProcessingLogPersistence.load()
    @Published private(set) var processingRecordingIDs: Set<UInt32> = []

    var canScan: Bool { central?.state == .poweredOn }
    var canLoadRecordings: Bool {
        recorderCommandChannelReady
            && transferHandle == nil
            && pendingTransfer == nil
            && !recordingsLoading
    }
    var canFetchRecording: Bool {
        recorderCommandChannelReady
            && transferHandle == nil
            && pendingTransfer == nil
            && !recordingsLoading
    }

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var metadataFallbackRequested = false
    private var recordingListRequestID: UUID?
    private var recordingListTimeoutWorkItem: DispatchWorkItem?
    private var recordingListRefreshWorkItem: DispatchWorkItem?
    private var recordingListPageWorkItem: DispatchWorkItem?
    private var recordingListPage = 0
    private var recordingListCommandType: UInt8 = 0x1B
    private var recordingListEntries: [UInt32: RecordingMetadata] = [:]
    private let secureSession = D3200SecureSession()
    private var pendingTransfer: RecordingMetadata?
    private var transferHandle: FileHandle?
    private var transferURL: URL?
    private var transferFileKey: Data?
    private var transferNonce: Data?
    private var transferExpectedBytes = 0
    private var transferReceivedBytes = 0
    private var lastLoggedTransferBucket = -1
    private let uploadClient = AnkerCoreUploadClient()
    private let onDeviceProcessor = OnDeviceProcessor()
    private var lastAutoRequestedID: UInt32?
    private var pendingReprocessIDs: Set<UInt32> = []
    private var reconnectPeripheral: CBPeripheral?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var userRequestedDisconnect = false
    private var reconnectFetches: [UInt32: RecordingMetadata] = [:]
    private var reconnectWaitLoggedIDs: Set<UInt32> = []
    private var logHandle: FileHandle?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    override init() {
        let initialURL = Self.makeCaptureURL()
        captureURL = initialURL
        super.init()
        openCapture(at: initialURL)
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "AnkerCore.central"]
        )
        record(kind: "capture", summary: "Started a new local diagnostic capture")
        restoreDownloadedRecordings()
        restoreReconnectFetches()
        reloadVoiceProfiles()
        syncWidgetSnapshot()
        if uploadConfigured { testUploadConnection() }
    }

    deinit {
        try? logHandle?.close()
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        characteristics.removeAll()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        record(kind: "scan", summary: "Started scanning for Bluetooth peripherals")
    }

    func stopScanning() {
        central.stopScan()
        isScanning = false
        record(kind: "scan", summary: "Stopped scanning")
    }

    func connect(to identifier: UUID) {
        guard let device = devices.first(where: { $0.id == identifier }) else { return }
        stopScanning()
        userRequestedDisconnect = false
        reconnectAttempt = 0
        UserDefaults.standard.set(true, forKey: Self.autoReconnectKey)
        rememberRecorder(device.peripheral)
        requestConnection(to: device.peripheral, reason: "Connecting to \(device.name)…")
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        userRequestedDisconnect = true
        UserDefaults.standard.set(false, forKey: Self.autoReconnectKey)
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        central.cancelPeripheralConnection(peripheral)
        record(kind: "disconnect", summary: "Requested disconnect", peripheral: peripheral)
    }

    func loadRecordings() {
        guard !recordingsLoading else { return }
        guard transferHandle == nil, pendingTransfer == nil, recorderCommandChannelReady else {
            recordingListState = "Recorder command channel is not ready"
            return
        }

        metadataFallbackRequested = false
        recordingsLoading = true
        let requestID = UUID()
        recordingListRequestID = requestID
        recordingListPage = 0
        recordingListCommandType = 0x1B
        recordingListEntries.removeAll()
        recordingListState = "Loading all recordings…"
        requestRecordingListPage(type: recordingListCommandType, page: recordingListPage, requestID: requestID)
    }

    private func sendRecordingListPage(type: UInt8, page: Int) -> Bool {
        guard page >= 0, page <= Int(UInt16.max),
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic,
              characteristic.service?.uuid.uuidString.uppercased()
                == "020CF5DA-0000-1000-8000-00805F9B34FB",
              characteristic.uuid.uuidString.uppercased()
                == "00007777-0000-1000-8000-00805F9B34FB"
        else { return false }

        let pageNumber = UInt16(page)
        let payload = Data([UInt8(pageNumber & 0xFF), UInt8(pageNumber >> 8)])
        let command = Self.d3200Command(type: type, id: 0x0E, payload: payload)
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        peripheral.writeValue(command, for: characteristic, type: writeType)
        record(
            kind: "command",
            summary: "Requested recording metadata (page \(page + 1))",
            peripheral: peripheral,
            service: characteristic.service?.uuid,
            characteristic: characteristic.uuid
        )
        return true
    }

    private func requestRecordingListPage(type: UInt8, page: Int, requestID: UUID) {
        guard recordingListRequestID == requestID, sendRecordingListPage(type: type, page: page) else {
            finishRecordingListRequest()
            recordingListState = "Recorder command channel is not ready"
            return
        }
        scheduleRecordingListTimeout(for: requestID)
    }

    private func scheduleRecordingListTimeout(for requestID: UUID) {
        recordingListTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recordingListRequestID == requestID else { return }
            let loadedCount = self.recordingListEntries.count
            let failedPage = self.recordingListPage + 1
            self.finishRecordingListRequest()
            self.recordingListState = loadedCount == 0
                ? "Recorder did not return its list — tap Refresh to retry"
                : "Loaded \(loadedCount); page \(failedPage) timed out"
        }
        recordingListTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func finishRecordingListRequest() {
        recordingListTimeoutWorkItem?.cancel()
        recordingListTimeoutWorkItem = nil
        recordingListPageWorkItem?.cancel()
        recordingListPageWorkItem = nil
        recordingListRequestID = nil
        recordingsLoading = false
    }

    private func handleRecordingListPage(_ page: RecordingListPage) {
        guard transferHandle == nil,
              pendingTransfer == nil,
              let requestID = recordingListRequestID
        else { return }
        guard page.commandType == recordingListCommandType else { return }

        recordingListTimeoutWorkItem?.cancel()
        recordingListTimeoutWorkItem = nil
        let previousCount = recordingListEntries.count
        for recording in page.recordings {
            recordingListEntries[recording.id] = recording
        }
        recordings = recordingListEntries.values.sorted { $0.id > $1.id }
        syncWidgetSnapshot()

        let foundNewRecordings = recordingListEntries.count > previousCount
        let recorderRepeatedFullPage = page.fileCount == 10 && !foundNewRecordings
        guard page.fileCount == 10,
              foundNewRecordings,
              recordingListPage < Int(UInt16.max)
        else {
            finishRecordingListRequest()
            if recordings.isEmpty {
                recordingListState = "No recordings found"
            } else if recorderRepeatedFullPage {
                recordingListState = "Loaded \(recordings.count); recorder repeated page \(recordingListPage + 1)"
            } else {
                recordingListState = "Loaded all \(recordings.count) recording(s)"
            }
            return
        }

        recordingListPage += 1
        let nextPage = recordingListPage
        recordingListState = "Loading all recordings… \(recordings.count) found"
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recordingListRequestID == requestID else { return }
            self.requestRecordingListPage(
                type: self.recordingListCommandType,
                page: nextPage,
                requestID: requestID
            )
        }
        recordingListPageWorkItem = work
        // Match the recorder SDK's normal command spacing and avoid overrunning BLE firmware.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scheduleRecordingListRefresh(after delay: TimeInterval = 0.4) {
        recordingListRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transferHandle == nil, self.pendingTransfer == nil else {
                self.scheduleRecordingListRefresh(after: 1)
                return
            }
            self.loadRecordings()
        }
        recordingListRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func fetchRecording(_ recording: RecordingMetadata) {
        if recordingsLoading {
            finishRecordingListRequest()
            recordingListState = recordings.isEmpty
                ? "Inventory paused for audio fetch"
                : "Loaded \(recordings.count) recording(s)"
        }
        guard transferHandle == nil, pendingTransfer == nil else {
            reconnectFetches[recording.id] = recording
            uploadState = "Recording queued behind the active audio transfer…"
            if reconnectWaitLoggedIDs.insert(recording.id).inserted {
                appendProcessingEvent(
                    recording: recording,
                    stage: .fetch,
                    state: .waiting,
                    title: "Fetch queued",
                    detail: "Another audio transfer is active. AnkerCore will fetch this recording next."
                )
            }
            return
        }
        guard recorderCommandChannelReady else {
            queueFetchUntilReconnected(recording)
            return
        }
        reconnectFetches.removeValue(forKey: recording.id)
        reconnectWaitLoggedIDs.remove(recording.id)
        appendProcessingEvent(
            recording: recording,
            stage: .fetch,
            state: .running,
            title: "Fetching recording",
            detail: "Preparing an encrypted transfer from Soundcore Work."
        )
        pendingTransfer = recording
        transferExpectedBytes = Int(recording.sizeBytes)
        transferReceivedBytes = 0
        lastLoggedTransferBucket = -1
        transferProgress = 0
        transferState = "Preparing secure transfer…"

        if secureSession.isReady {
            requestPendingRecording()
        } else {
            let publicKey = secureSession.beginHandshake()
            guard sendKnownCommand(type: 0x2E, id: 0x01, payload: publicKey) else {
                suspendTransferForReconnect()
                scheduleReconnect(to: connectedPeripheral ?? savedRecorder())
                return
            }
            record(kind: "secure-transfer", summary: "Requested an ephemeral encrypted session")
        }
    }

    func saveUploadConfiguration(endpoint: String, token: String, webhookURL: String = "") -> String? {
        do {
            try AnkerCoreUploadClient.saveConfiguration(endpoint: endpoint, token: token, webhookURL: webhookURL)
            uploadEndpoint = AnkerCoreUploadClient.savedEndpoint
            uploadConfigured = true
            uploadState = AnkerCoreUploadClient.savedWebhookURL.isEmpty
                ? "Automatic processing is ready"
                : "Automatic processing and webhook delivery are ready"
            testUploadConnection()
            refreshTasks()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func clearUploadToken() {
        do {
            try AnkerCoreUploadClient.clearToken()
            uploadConfigured = false
            uploadState = "Automatic processing is off"
            openTasks = []
            tasksState = "Connect your private route to load tasks"
            syncWidgetSnapshot()
        } catch {
            uploadState = error.localizedDescription
        }
    }

    func refreshTasks() {
        guard uploadConfigured, !tasksLoading else { return }
        tasksLoading = true
        tasksState = "Refreshing…"
        Task {
            do {
                let tasks = try await uploadClient.fetchOpenTasks()
                await MainActor.run {
                    openTasks = tasks
                    tasksState = tasks.isEmpty ? "You’re all caught up" : "\(tasks.count) open"
                    tasksLoading = false
                    syncWidgetSnapshot()
                }
            } catch {
                await MainActor.run {
                    tasksState = error.localizedDescription
                    tasksLoading = false
                }
            }
        }
    }

    func testUploadConnection() {
        guard uploadConfigured else {
            connectionCheckState = "Save the private connection first"
            return
        }
        connectionCheckState = "Testing Worker and Notion access…"
        Task {
            do {
                let diagnostics = try await uploadClient.routingDiagnostics()
                await MainActor.run {
                    if diagnostics.ok {
                        connectionCheckState = "Worker authenticated · Notion routing ready"
                    } else {
                        connectionCheckState = "Notion configuration needs repair"
                    }
                }
            } catch {
                await MainActor.run {
                    connectionCheckState = Self.safeProcessingFailure(
                        error,
                        fallback: "The iPhone could not reach the configured Worker."
                    )
                }
            }
        }
    }

    func completeTask(_ task: AnkerCoreTask) {
        guard !tasksLoading else { return }
        tasksLoading = true
        tasksState = "Completing task…"
        Task {
            do {
                _ = try await uploadClient.completeTask(id: task.id)
                await MainActor.run {
                    openTasks.removeAll { $0.id == task.id }
                    tasksState = openTasks.isEmpty ? "You’re all caught up" : "\(openTasks.count) open"
                    tasksLoading = false
                    syncWidgetSnapshot()
                }
            } catch {
                await MainActor.run {
                    tasksState = error.localizedDescription
                    tasksLoading = false
                }
            }
        }
    }

    func reloadVoiceProfiles() {
        Task {
            do {
                let profiles = try await VoiceIdentityEngine.shared.profiles()
                await MainActor.run {
                    voiceProfiles = profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    voiceIdentityState = profiles.isEmpty ? "No voice profiles enrolled" : "\(profiles.count) enrolled on this iPhone"
                }
            } catch {
                await MainActor.run { voiceIdentityState = error.localizedDescription }
            }
        }
    }

    func enrollVoice(name: String, recording: RecordingMetadata, consentConfirmed: Bool) async -> String? {
        guard let url = downloadedRecordings[recording.id], url.pathExtension == "ogg" else {
            return "Fetch the playable recording before enrolling this voice."
        }
        await MainActor.run { voiceIdentityState = "Building a private voice signature…" }
        do {
            _ = try await VoiceIdentityEngine.shared.enroll(
                name: name,
                from: url,
                consentConfirmed: consentConfirmed
            )
            reloadVoiceProfiles()
            return nil
        } catch {
            await MainActor.run { voiceIdentityState = error.localizedDescription }
            return error.localizedDescription
        }
    }

    func deleteVoiceProfile(_ profile: VoiceProfile) {
        Task {
            do {
                try await VoiceIdentityEngine.shared.delete(id: profile.id)
                reloadVoiceProfiles()
            } catch {
                await MainActor.run { voiceIdentityState = error.localizedDescription }
            }
        }
    }

    func processingLog(for recordingID: UInt32) -> RecordingProcessingLog? {
        processingLogs[recordingID]
    }

    func isProcessing(_ recording: RecordingMetadata) -> Bool {
        processingRecordingIDs.contains(recording.id)
            || pendingTransfer?.id == recording.id
            || reconnectFetches[recording.id] != nil
    }

    func canReprocess(_ recording: RecordingMetadata) -> Bool {
        guard uploadConfigured, !isProcessing(recording) else { return false }
        return validatedDownloadedRecording(for: recording.id) != nil || canFetchRecording
    }

    func reprocessAvailability(for recording: RecordingMetadata) -> String {
        if isProcessing(recording) { return "This recording is already processing." }
        if !uploadConfigured { return "Connect the private Worker route in Settings before retrying." }
        if validatedDownloadedRecording(for: recording.id) != nil { return "The saved audio will be processed again." }
        if canFetchRecording { return "The audio will be fetched from Soundcore Work, then processed again." }
        return "Reconnect Soundcore Work so AnkerCore can fetch the audio again."
    }

    func reprocessRecording(_ recording: RecordingMetadata) {
        guard !isProcessing(recording) else { return }
        guard uploadConfigured else {
            uploadState = "Reconnect the private Worker route before retrying"
            appendProcessingEvent(
                recording: recording,
                stage: .routing,
                state: .attention,
                title: "Retry needs configuration",
                detail: "Connect the private Worker route in Settings, then try again."
            )
            return
        }

        appendProcessingEvent(
            recording: recording,
            stage: .capture,
            state: .running,
            title: "Manual retry requested",
            detail: "Starting a new processing attempt. Existing Notion artifacts will be reused."
        )

        if let fileURL = validatedDownloadedRecording(for: recording.id) {
            uploadRecording(fileURL, recording: recording, reprocess: true)
        } else if canFetchRecording {
            pendingReprocessIDs.insert(recording.id)
            fetchRecording(recording)
        } else {
            uploadState = "Reconnect Soundcore Work to retry this recording"
            appendProcessingEvent(
                recording: recording,
                stage: .fetch,
                state: .attention,
                title: "Retry waiting for recorder",
                detail: "The local audio is unavailable. Reconnect Soundcore Work and retry to fetch it again."
            )
        }
    }

    func clearProcessingHistory() {
        processingLogs = [:]
        ProcessingLogPersistence.clear()
        syncWidgetSnapshot()
    }

    func startNewCapture() {
        try? logHandle?.close()
        let url = Self.makeCaptureURL()
        captureURL = url
        events.removeAll()
        openCapture(at: url)
        record(kind: "capture", summary: "Started a new local diagnostic capture")
        if let peripheral = connectedPeripheral {
            record(
                kind: "connection-snapshot",
                summary: connectionState,
                peripheral: peripheral
            )
            for item in characteristics {
                record(
                    kind: "characteristic-snapshot",
                    summary: "Cached \(item.characteristicUUID): \(item.properties)",
                    peripheral: peripheral,
                    service: CBUUID(string: item.serviceUUID),
                    characteristic: CBUUID(string: item.characteristicUUID)
                )
            }
        }
    }

    private func openCapture(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }

    private static func makeCaptureURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "ankercore-capture-\(formatter.string(from: Date())).jsonl"
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(name)
    }

    private func record(
        kind: String,
        summary: String,
        peripheral: CBPeripheral? = nil,
        service: CBUUID? = nil,
        characteristic: CBUUID? = nil,
        data: Data? = nil
    ) {
        let event = ProbeEvent(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            summary: summary,
            peripheralID: peripheral?.identifier.uuidString,
            serviceUUID: service?.uuidString,
            characteristicUUID: characteristic?.uuidString,
            byteCount: data?.count,
            hexPreview: data.map { Self.hex($0.prefix(96)) },
            valueBase64: data?.base64EncodedString()
        )
        events.insert(event, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }

        guard var encoded = try? encoder.encode(event) else { return }
        encoded.append(0x0A)
        do {
            try logHandle?.seekToEnd()
            try logHandle?.write(contentsOf: encoded)
        } catch {
            // Capture failure stays local and must not interrupt Bluetooth discovery.
        }
    }

    private static func hex<D: DataProtocol>(_ data: D) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func propertiesDescription(_ properties: CBCharacteristicProperties) -> String {
        var values: [String] = []
        if properties.contains(.read) { values.append("read") }
        if properties.contains(.notify) { values.append("notify") }
        if properties.contains(.indicate) { values.append("indicate") }
        if properties.contains(.write) { values.append("write") }
        if properties.contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if properties.contains(.authenticatedSignedWrites) { values.append("signedWrite") }
        if properties.contains(.broadcast) { values.append("broadcast") }
        if properties.contains(.extendedProperties) { values.append("extended") }
        return values.isEmpty ? "no exposed properties" : values.joined(separator: ", ")
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        return data[offset ..< offset + 4].enumerated().reduce(UInt32(0)) { value, item in
            value | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    private static func decodedD3200Event(_ data: Data) -> D3200Event? {
        guard data.count >= 10,
              data[0] == 0x09,
              data[1] == 0xFF,
              data[2] == 0x00,
              data[3] == 0x00
        else { return nil }

        let declaredLength = Int(data[7]) | (Int(data[8]) << 8)
        guard declaredLength == data.count else { return nil }
        let expectedChecksum = data.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
        guard expectedChecksum == data.last else { return nil }

        let commandType = data[5]
        let commandID = data[6]
        let payload = Data(data[9 ..< data.count - 1])

        if commandType == 0x1A,
           commandID == 0x06,
           let fileID = littleEndianUInt32(payload, at: 0) {
            return D3200Event(
                summary: "Recording started · file \(fileID)",
                state: "Recording",
                fileID: fileID,
                duration: nil
            )
        }

        if commandType == 0x18, commandID == 0x82, let status = payload.first {
            switch status {
            case 0:
                // Observed D3200 stop layout: status, result, duration u32, fileID u32.
                let duration = littleEndianUInt32(payload, at: 2)
                    ?? littleEndianUInt32(payload, at: 1)
                let fileID = littleEndianUInt32(payload, at: 6)
                let durationText = duration.map { " · \($0)s" } ?? ""
                let fileText = fileID.map { " · file \($0)" } ?? ""
                return D3200Event(
                    summary: "Recording stopped\(durationText)\(fileText)",
                    state: "Stopped",
                    fileID: fileID,
                    duration: duration
                )
            case 1:
                return D3200Event(
                    summary: "Recording resumed",
                    state: "Recording",
                    fileID: nil,
                    duration: nil
                )
            case 2:
                return D3200Event(
                    summary: "Recording paused",
                    state: "Paused",
                    fileID: nil,
                    duration: nil
                )
            default:
                break
            }
        }

        return D3200Event(
            summary: String(format: "D3200 response · type %02X · command %02X", commandType, commandID),
            state: nil,
            fileID: nil,
            duration: nil
        )
    }

    private static func d3200Command(type: UInt8, id: UInt8, payload: Data) -> Data {
        var command = Data([0x08, 0xEE, 0x00, 0x00, 0x00, type, id, 0x00, 0x00])
        command.append(payload)
        let totalLength = command.count + 1
        command[7] = UInt8(totalLength & 0xFF)
        command[8] = UInt8((totalLength >> 8) & 0xFF)
        command.append(command.reduce(UInt8(0)) { $0 &+ $1 })
        return command
    }

    @discardableResult
    private func sendKnownCommand(type: UInt8, id: UInt8, payload: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected,
              let characteristic = writeCharacteristic
        else { return false }
        let command = Self.d3200Command(type: type, id: id, payload: payload)
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        peripheral.writeValue(command, for: characteristic, type: writeType)
        return true
    }

    private func requestPendingRecording() {
        guard let recording = pendingTransfer else { return }
        var payload = Data(repeating: 0, count: 4)
        payload.append(Self.littleEndianData(recording.id))
        payload.append(0x00) // Offline transfer, never a live microphone stream.
        guard sendKnownCommand(type: 0x1A, id: 0x07, payload: payload) else {
            suspendTransferForReconnect()
            scheduleReconnect(to: connectedPeripheral ?? savedRecorder())
            return
        }
        transferState = "Requesting encrypted recording…"
        record(kind: "secure-transfer", summary: "Requested encrypted audio for file \(recording.id)")
    }

    private static func littleEndianData(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func validatedD3200Payload(_ data: Data) -> (type: UInt8, id: UInt8, payload: Data)? {
        guard data.count >= 10,
              data[0] == 0x09,
              data[1] == 0xFF,
              Int(data[7]) | (Int(data[8]) << 8) == data.count,
              data.dropLast().reduce(UInt8(0), { $0 &+ $1 }) == data.last
        else { return nil }
        return (data[5], data[6], Data(data[9 ..< data.count - 1]))
    }

    private func handleSecureTransferFrame(_ data: Data) -> String? {
        guard let frame = Self.validatedD3200Payload(data) else { return nil }

        if frame.type == 0x2E, frame.id == 0x01 {
            do {
                try secureSession.completeHandshake(payload: frame.payload)
                transferState = "Secure session established"
                requestPendingRecording()
                return "Verified encrypted session; key material omitted from capture"
            } catch {
                failTransfer(error.localizedDescription)
                return "Encrypted session failed; key material omitted from capture"
            }
        }

        if frame.type == 0x1A, frame.id == 0x07 {
            do {
                try prepareTransfer(from: frame.payload)
                return "Verified encrypted file header; key material omitted from capture"
            } catch {
                failTransfer(error.localizedDescription)
                return "Encrypted file header rejected; key material omitted from capture"
            }
        }

        if frame.type == 0x1A, frame.id == 0x08 || frame.id == 0x12 {
            do {
                try appendTransferSlices(from: frame.payload)
                let bucket = Int(transferProgress * 10)
                guard bucket > lastLoggedTransferBucket else { return "" }
                lastLoggedTransferBucket = bucket
                return "Encrypted audio transfer · \(min(bucket * 10, 100))%"
            } catch {
                failTransfer(error.localizedDescription)
                return "Encrypted audio slice rejected"
            }
        }

        if frame.type == 0x1A, frame.id == 0x0A, transferHandle != nil {
            finishTransfer()
            return "Encrypted audio transfer completed"
        }
        return nil
    }

    private func prepareTransfer(from payload: Data) throws {
        guard let target = pendingTransfer,
              payload.count >= 87,
              let fileID = Self.littleEndianUInt32(payload, at: 0),
              let size = Self.littleEndianUInt32(payload, at: 4),
              fileID == target.id,
              payload[86] == 0
        else { throw D3200CryptoError.invalidFileKey }

        let nonce = Data(payload[8 ..< 24])
        let encryptedFileKey = Data(payload[24 ..< 70])
        let sessionNonce = Data(payload[70 ..< 86])
        transferFileKey = try secureSession.unwrapFileKey(
            encrypted: encryptedFileKey,
            sessionNonce: sessionNonce
        )
        transferNonce = nonce
        if size > 0 { transferExpectedBytes = Int(size) }

        let directory = Self.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(target.id).opus.raw")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        ) else { throw CocoaError(.fileWriteUnknown) }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try? protectedURL.setResourceValues(values)
        transferURL = url
        transferHandle = try FileHandle(forWritingTo: url)
        transferState = "Downloading and decrypting…"
        appendProcessingEvent(
            recording: target,
            stage: .fetch,
            state: .running,
            title: "Secure transfer established",
            detail: "Downloading and decrypting the recording on this iPhone."
        )
    }

    private func appendTransferSlices(from payload: Data) throws {
        guard let handle = transferHandle,
              let fileKey = transferFileKey,
              let nonce = transferNonce
        else { throw D3200CryptoError.invalidFileKey }

        var offset = 0
        while payload.count - offset >= 165 {
            guard let sequence = Self.littleEndianUInt32(payload, at: offset) else { break }
            offset += 5 // sequence u32 + flags u8
            let encrypted = Data(payload[offset ..< offset + 160])
            offset += 160
            if offset < payload.count { offset += 1 } // packet pad byte
            let plain = try secureSession.decryptAudioChunk(
                encrypted,
                fileKey: fileKey,
                nonce: nonce,
                sequence: sequence
            )
            let remaining = max(0, transferExpectedBytes - transferReceivedBytes)
            let bytesToWrite = transferExpectedBytes > 0 ? min(remaining, plain.count) : plain.count
            if bytesToWrite > 0 {
                try handle.write(contentsOf: plain.prefix(bytesToWrite))
                transferReceivedBytes += bytesToWrite
            }
        }
        transferProgress = transferExpectedBytes > 0
            ? min(1, Double(transferReceivedBytes) / Double(transferExpectedBytes))
            : 0
        if transferExpectedBytes > 0, transferReceivedBytes >= transferExpectedBytes {
            finishTransfer()
        }
    }

    private func finishTransfer() {
        guard let target = pendingTransfer, let rawURL = transferURL else { return }
        try? transferHandle?.synchronize()
        try? transferHandle?.close()
        transferHandle = nil
        var finalURL = rawURL
        var conversionSucceeded = false
        do {
            let rawAudio = try Data(contentsOf: rawURL)
            let oggAudio = try OggOpusMuxer.mux(rawFrames: rawAudio)
            let oggURL = rawURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("ogg")
            try oggAudio.write(to: oggURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: oggURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = oggURL
            try? protectedURL.setResourceValues(values)
            try FileManager.default.removeItem(at: rawURL)
            finalURL = oggURL
            conversionSucceeded = true
        } catch {
            // Preserve the decrypted raw file if container creation ever fails.
            transferState = "Saved raw audio; playable conversion failed"
        }
        transferProgress = 1
        downloadedRecordings[target.id] = finalURL
        if conversionSucceeded, finalURL.pathExtension == "ogg" {
            transferState = "Saved playable audio securely on this iPhone"
            appendProcessingEvent(
                recording: target,
                stage: .fetch,
                state: .succeeded,
                title: "Recording fetched",
                detail: "The playable audio file was saved securely on this iPhone."
            )
            let reprocess = pendingReprocessIDs.remove(target.id) != nil
            uploadRecording(finalURL, recording: target, reprocess: reprocess)
            record(kind: "secure-transfer", summary: "Saved playable file \(target.id) locally; audio omitted from capture")
        } else {
            pendingReprocessIDs.remove(target.id)
            appendProcessingEvent(
                recording: target,
                stage: .fetch,
                state: .failed,
                title: "Audio conversion failed",
                detail: "The encrypted recording was fetched, but a playable audio file could not be created."
            )
            record(kind: "secure-transfer", summary: "Saved raw file \(target.id) locally; audio omitted from capture")
        }
        pendingTransfer = nil
        transferURL = nil
        transferFileKey = nil
        transferNonce = nil
        DispatchQueue.main.async { [weak self] in
            self?.resumeReconnectFetchesIfReady()
            self?.scheduleRecordingListRefresh(after: 1)
        }
    }

    private func uploadRecording(_ fileURL: URL, recording: RecordingMetadata, reprocess: Bool = false) {
        guard uploadConfigured else {
            uploadState = "Saved locally — add the private token to process automatically"
            appendProcessingEvent(
                recording: recording,
                stage: .routing,
                state: .waiting,
                title: "Waiting for cloud connection",
                detail: "The audio is saved locally. Add the private Worker connection to process it."
            )
            return
        }
        guard !processingRecordingIDs.contains(recording.id) else { return }
        processingRecordingIDs.insert(recording.id)
        uploadState = "Transcribing on this iPhone…"
        processingMode = "On-device preferred"
        lastDestinationURL = nil
        appendProcessingEvent(
            recording: recording,
            stage: .transcription,
            state: .running,
            title: "On-device transcription started",
            detail: "AnkerCore is attempting to transcribe the recording without uploading audio."
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.processingRecordingIDs.remove(recording.id) }
            let transcript: String
            do {
                transcript = try await onDeviceProcessor.transcribe(fileURL: fileURL)
                await MainActor.run {
                    self.appendProcessingEvent(
                        recording: recording,
                        stage: .transcription,
                        state: .succeeded,
                        title: "On-device transcription complete",
                        detail: "Speech was transcribed on this iPhone; transcript content is omitted from this log."
                    )
                }
            } catch {
                await MainActor.run {
                    uploadState = "Local speech unavailable — using cloud transcription…"
                    processingMode = "Cloud transcription fallback"
                    self.appendProcessingEvent(
                        recording: recording,
                        stage: .transcription,
                        state: .running,
                        title: "Using cloud transcription fallback",
                        detail: "The local speech model was unavailable, so the encrypted connection is sending audio to the configured Worker."
                    )
                }
                do {
                    let result = try await uploadClient.upload(fileURL: fileURL, recording: recording, reprocess: reprocess)
                    await applyUploadResult(result, mode: "Cloud transcription fallback", recording: recording)
                } catch {
                    await MainActor.run {
                        uploadState = error.localizedDescription
                        self.appendProcessingEvent(
                            recording: recording,
                            stage: .routing,
                            state: .failed,
                            title: "Cloud processing failed",
                            detail: Self.safeProcessingFailure(error, fallback: "The configured Worker could not process this recording.")
                        )
                    }
                }
                return
            }

            if #available(iOS 26.0, *) {
                await routeLocallyTranscribed(transcript, recording: recording, reprocess: reprocess)
            }
        }
    }

    @available(iOS 26.0, *)
    private func routeLocallyTranscribed(_ transcript: String, recording: RecordingMetadata, reprocess: Bool) async {
        var analysis: OnDeviceAnalysis?
        await MainActor.run {
            uploadState = "Sorting on this iPhone…"
            self.appendProcessingEvent(
                recording: recording,
                stage: .classification,
                state: .running,
                title: "On-device sorting started",
                detail: "Classifying meetings, tasks, ideas, and work area on this iPhone."
            )
        }
        do {
            analysis = try await onDeviceProcessor.classify(transcript: transcript, recordedAt: recording.recordedAt)
            await MainActor.run {
                self.appendProcessingEvent(
                    recording: recording,
                    stage: .classification,
                    state: .succeeded,
                    title: "On-device sorting complete",
                    detail: "Structured meeting, task, and idea metadata was created locally."
                )
            }
        } catch {
            await MainActor.run {
                uploadState = "Using transcript-only cloud sorting…"
                processingMode = "Local transcript · cloud sorting"
                self.appendProcessingEvent(
                    recording: recording,
                    stage: .classification,
                    state: .running,
                    title: "Using cloud sorting fallback",
                    detail: "Only transcript text is being sent to the configured Worker; audio remains on this iPhone."
                )
            }
        }

        do {
            await MainActor.run {
                self.appendProcessingEvent(
                    recording: recording,
                    stage: .routing,
                    state: .running,
                    title: "Routing to Notion",
                    detail: "Creating and linking the extracted records in the configured private databases."
                )
            }
            let result = try await uploadClient.routeTranscript(
                transcript,
                analysis: analysis,
                recording: recording,
                reprocess: reprocess
            )
            await applyUploadResult(
                result,
                mode: analysis == nil ? "Local transcript · cloud sorting" : "Fully on-device AI",
                recording: recording
            )
        } catch {
            // The local transcript is already available. Do not upload audio merely because delivery failed.
            await MainActor.run {
                uploadState = error.localizedDescription
                self.appendProcessingEvent(
                    recording: recording,
                    stage: .routing,
                    state: .failed,
                    title: "Notion routing failed",
                    detail: Self.safeProcessingFailure(error, fallback: "The transcript is still on this iPhone, but the configured Worker could not route it.")
                )
            }
        }
    }

    @MainActor
    private func applyUploadResult(_ result: AnkerCoreUploadResult, mode: String, recording: RecordingMetadata) {
        processingMode = mode
        let webhookSuffix: String
        if result.webhook?.configured == true {
            webhookSuffix = result.webhook?.delivered == true ? " · webhook sent" : " · webhook failed"
        } else {
            webhookSuffix = ""
        }
        let links = processingLinks(from: result)
        let webhookFailed = result.webhook?.configured == true && result.webhook?.delivered != true
        if result.webhook?.configured == true {
            appendProcessingEvent(
                recording: recording,
                stage: .delivery,
                state: result.webhook?.delivered == true ? .succeeded : .attention,
                title: result.webhook?.delivered == true ? "Webhook delivered" : "Webhook delivery failed",
                detail: result.webhook?.delivered == true
                    ? "The configured webhook accepted the sanitized processing event."
                    : "Notion processing completed, but the optional webhook did not accept the event."
            )
        }
        if let destination = result.routed?.destination {
            lastDestinationURL = destination
            let count = result.routed?.itemCount ?? result.routed?.destinations?.count ?? 1
            uploadState = "Processed \(count) \(count == 1 ? "item" : "items") · \(result.routed?.area ?? "Needs Review")\(webhookSuffix)"
            appendProcessingEvent(
                recording: recording,
                stage: .routing,
                state: webhookFailed ? .attention : .succeeded,
                title: webhookFailed ? "Processed with a delivery warning" : "Processing complete",
                detail: "Created \(count) \(count == 1 ? "item" : "items") in Notion as \(result.routed?.area ?? "Needs Review") using \(mode).",
                links: links
            )
            refreshTasks()
        } else if result.routed?.reason == "already_routed" {
            lastDestinationURL = result.source
            uploadState = "This recording was already processed\(webhookSuffix)"
            appendProcessingEvent(
                recording: recording,
                stage: .routing,
                state: webhookFailed ? .attention : .succeeded,
                title: "Recording already processed",
                detail: "The Worker found an existing routed record and did not create a duplicate.",
                links: links
            )
        } else {
            lastDestinationURL = result.source
            uploadState = "Transcribed; open Notion to review routing\(webhookSuffix)"
            appendProcessingEvent(
                recording: recording,
                stage: .routing,
                state: .attention,
                title: "Routing needs review",
                detail: "Transcription completed, but AnkerCore could not confidently place the extracted content.",
                links: links
            )
        }
    }

    private func automaticallyFetchStoppedRecording(fileID: UInt32, duration: UInt32?) {
        guard lastAutoRequestedID != fileID else { return }
        lastAutoRequestedID = fileID
        uploadState = "Recording stopped — fetching audio automatically…"
        let metadata = RecordingMetadata(
            id: fileID,
            endTime: duration.map { fileID &+ $0 },
            sizeBytes: 0
        )
        if !recordings.contains(where: { $0.id == fileID }) {
            recordings.insert(metadata, at: 0)
        }
        recordings.sort { $0.id > $1.id }
        recordingListState = "New recording detected"
        syncWidgetSnapshot()
        appendProcessingEvent(
            recording: metadata,
            stage: .capture,
            state: .running,
            title: "Recording stopped",
            detail: "Queued for automatic fetch and processing."
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.fetchRecording(metadata)
        }
    }

    private var recorderCommandChannelReady: Bool {
        connectedPeripheral?.state == .connected && writeCharacteristic != nil
    }

    private static let preferredRecorderKey = "AnkerCore.preferred-recorder-id"
    private static let autoReconnectKey = "AnkerCore.auto-reconnect-enabled"

    private var autoReconnectEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoReconnectKey) == nil
            || UserDefaults.standard.bool(forKey: Self.autoReconnectKey)
    }

    private func rememberRecorder(_ peripheral: CBPeripheral) {
        reconnectPeripheral = peripheral
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.preferredRecorderKey)
    }

    private func savedRecorder() -> CBPeripheral? {
        if let reconnectPeripheral { return reconnectPeripheral }
        guard let value = UserDefaults.standard.string(forKey: Self.preferredRecorderKey),
              let identifier = UUID(uuidString: value)
        else { return nil }
        let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first
        if let peripheral { reconnectPeripheral = peripheral }
        return peripheral
    }

    private func requestConnection(to peripheral: CBPeripheral, reason: String) {
        guard central.state == .poweredOn else { return }
        rememberRecorder(peripheral)
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            connectedPeripheral = peripheral
            connectedPeripheralID = peripheral.identifier
            connectionState = "Restoring recorder controls…"
            writeCharacteristic = nil
            peripheral.discoverServices(nil)
        case .connecting:
            connectionState = reason
        default:
            connectionState = reason
            central.connect(
                peripheral,
                options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
            )
            record(kind: "connect", summary: reason, peripheral: peripheral)
        }
    }

    private func scheduleReconnect(to peripheral: CBPeripheral? = nil) {
        guard autoReconnectEnabled, !userRequestedDisconnect, central.state == .poweredOn else { return }
        if let peripheral { rememberRecorder(peripheral) }
        guard let target = peripheral ?? savedRecorder() else { return }
        guard target.state != .connected, target.state != .connecting else { return }

        reconnectWorkItem?.cancel()
        let attempt = reconnectAttempt
        let delay = min(pow(2.0, Double(attempt)), 15.0)
        reconnectAttempt += 1
        connectionState = attempt == 0 ? "Reconnecting to Soundcore Work…" : "Recorder reconnect queued…"
        let work = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, !self.userRequestedDisconnect else { return }
            self.requestConnection(to: target, reason: "Reconnecting to Soundcore Work…")
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reconnectSavedRecorderIfNeeded() {
        guard autoReconnectEnabled,
              connectedPeripheral == nil,
              let peripheral = savedRecorder()
        else { return }
        scheduleReconnect(to: peripheral)
    }

    private func restoreReconnectFetches() {
        for log in processingLogs.values {
            guard log.latestEvent?.stage == .fetch,
                  log.latestEvent?.state == .waiting,
                  downloadedRecordings[log.id] == nil
            else { continue }
            reconnectFetches[log.id] = RecordingMetadata(id: log.id, endTime: nil, sizeBytes: 0)
            reconnectWaitLoggedIDs.insert(log.id)
        }
    }

    private func queueFetchUntilReconnected(_ recording: RecordingMetadata) {
        reconnectFetches[recording.id] = recording
        uploadState = "Recording saved — reconnecting to fetch audio…"
        transferState = "Waiting for recorder to reconnect"
        if reconnectWaitLoggedIDs.insert(recording.id).inserted {
            appendProcessingEvent(
                recording: recording,
                stage: .fetch,
                state: .waiting,
                title: "Waiting for recorder",
                detail: "AnkerCore is reconnecting to Soundcore Work and will fetch this recording automatically."
            )
        }
        if let peripheral = connectedPeripheral ?? savedRecorder(), peripheral.state == .connected {
            writeCharacteristic = nil
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        } else {
            scheduleReconnect(to: connectedPeripheral ?? savedRecorder())
        }
    }

    private func resumeReconnectFetchesIfReady() {
        guard recorderCommandChannelReady,
              transferHandle == nil,
              pendingTransfer == nil,
              let recording = reconnectFetches.values.sorted(by: { $0.id < $1.id }).first
        else { return }
        uploadState = "Recorder reconnected — fetching queued audio…"
        fetchRecording(recording)
    }

    private func suspendTransferForReconnect() {
        guard let recording = pendingTransfer else { return }
        try? transferHandle?.close()
        transferHandle = nil
        if let transferURL { try? FileManager.default.removeItem(at: transferURL) }
        pendingTransfer = nil
        transferURL = nil
        transferFileKey = nil
        transferNonce = nil
        transferProgress = 0
        reconnectFetches[recording.id] = recording
        transferState = "Transfer interrupted — reconnecting"
        uploadState = "Recorder connection interrupted — retrying automatically…"
        if reconnectWaitLoggedIDs.insert(recording.id).inserted {
            appendProcessingEvent(
                recording: recording,
                stage: .fetch,
                state: .waiting,
                title: "Transfer interrupted",
                detail: "The Bluetooth link dropped. AnkerCore will reconnect and restart this recording transfer automatically."
            )
        }
    }

    private func failTransfer(_ message: String) {
        let failedRecording = pendingTransfer
        try? transferHandle?.close()
        transferHandle = nil
        if let transferURL { try? FileManager.default.removeItem(at: transferURL) }
        transferState = "Transfer failed: \(message)"
        transferProgress = 0
        pendingTransfer = nil
        transferURL = nil
        transferFileKey = nil
        transferNonce = nil
        if let failedRecording {
            pendingReprocessIDs.remove(failedRecording.id)
            appendProcessingEvent(
                recording: failedRecording,
                stage: .fetch,
                state: .failed,
                title: "Recording fetch failed",
                detail: Self.safeTransferFailure(message)
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.resumeReconnectFetchesIfReady()
        }
    }

    private func appendProcessingEvent(
        recording: RecordingMetadata,
        stage: RecordingProcessingStage,
        state: RecordingProcessingState,
        title: String,
        detail: String,
        links: [RecordingProcessingLink] = []
    ) {
        var log = processingLogs[recording.id] ?? RecordingProcessingLog(
            id: recording.id,
            recordedAt: recording.recordedAt,
            events: []
        )
        log.recordedAt = recording.recordedAt
        log.events.append(RecordingProcessingEvent(stage: stage, state: state, title: title, detail: detail, links: links))
        log.events = Array(log.events.suffix(50))

        var updated = processingLogs
        updated[recording.id] = log
        if updated.count > 100,
           let oldest = updated.values.min(by: { $0.recordedAt < $1.recordedAt }) {
            updated.removeValue(forKey: oldest.id)
        }
        processingLogs = updated
        ProcessingLogPersistence.save(updated)
        syncWidgetSnapshot()
    }

    private func syncWidgetSnapshot() {
        var recordingDates = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0.recordedAt) })
        for log in processingLogs.values { recordingDates[log.id] = log.recordedAt }

        let recordingSnapshots = recordingDates.map { id, recordedAt in
            let log = processingLogs[id]
            let event = log?.latestEvent
            let destination = log?.events.reversed().lazy
                .flatMap(\.links)
                .first(where: { $0.url.scheme == "https" })?.url
            return AnkerCoreWidgetRecording(
                id: id,
                recordedAt: recordedAt,
                stage: event.map { Self.widgetStageName($0.stage) } ?? "Captured",
                state: event?.state.rawValue ?? RecordingProcessingState.waiting.rawValue,
                title: String((event?.title ?? "Not processed yet").prefix(100)),
                destination: destination
            )
        }
        .sorted { $0.recordedAt > $1.recordedAt }

        let taskSnapshots = openTasks.prefix(20).map { task in
            AnkerCoreWidgetTask(
                id: task.id,
                title: String(task.title.prefix(120)),
                due: task.dueDate,
                priority: task.priority,
                area: task.area,
                url: task.url
            )
        }
        AnkerCoreWidgetStore.save(AnkerCoreWidgetSnapshot(
            updatedAt: Date(),
            recordings: Array(recordingSnapshots.prefix(20)),
            tasks: taskSnapshots
        ))
    }

    private static func widgetStageName(_ stage: RecordingProcessingStage) -> String {
        switch stage {
        case .capture: "Captured"
        case .fetch: "Audio fetch"
        case .transcription: "Transcription"
        case .classification: "AI sorting"
        case .routing: "Notion routing"
        case .delivery: "Delivery"
        }
    }

    private func restoreDownloadedRecordings() {
        let directory = Self.recordingsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.pathExtension.lowercased() == "ogg" {
            guard let recordingID = UInt32(url.deletingPathExtension().lastPathComponent),
                  Self.isValidStoredRecording(url)
            else { continue }
            downloadedRecordings[recordingID] = url
        }
    }

    private func validatedDownloadedRecording(for recordingID: UInt32) -> URL? {
        guard let url = downloadedRecordings[recordingID], Self.isValidStoredRecording(url) else { return nil }
        return url
    }

    private static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnkerCore Recordings", isDirectory: true)
    }

    private static func isValidStoredRecording(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "ogg",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              (100 ... 20 * 1024 * 1024).contains(size),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x4F, 0x67, 0x67, 0x53])
    }

    private func processingLinks(from result: AnkerCoreUploadResult) -> [RecordingProcessingLink] {
        var links: [RecordingProcessingLink] = []
        var seenURLs: Set<String> = []
        func add(_ title: String, _ url: URL?) {
            guard let url, url.scheme == "https", seenURLs.insert(url.absoluteString).inserted else { return }
            links.append(RecordingProcessingLink(title: title, url: url))
        }

        for destination in result.routed?.destinations ?? [] {
            let kind = destination.kind.replacingOccurrences(of: "_", with: " ").capitalized
            add("Open \(kind)", destination.destination)
            add("Open \(kind) database", destination.database)
        }
        add("Open routed item", result.routed?.destination)
        add("Open destination database", result.routed?.database)
        add("Open source transcript", result.source)
        return links
    }

    private static func safeProcessingFailure(_ error: Error, fallback: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The Worker connection timed out. Check the service URL and try again."
            case .cannotFindHost:
                return "The configured Worker hostname could not be found. Check the service URL."
            case .cannotConnectToHost:
                return "The iPhone could not connect to the configured Worker."
            case .notConnectedToInternet:
                return "The iPhone is not connected to the internet."
            case .networkConnectionLost:
                return "The Worker connection was interrupted. Try again."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "The configured Worker did not provide a trusted secure connection."
            default:
                return fallback
            }
        }
        guard let uploadError = error as? AnkerCoreUploadError else { return fallback }
        switch uploadError {
        case .invalidEndpoint:
            return "The configured service URL is invalid. Update it in Settings and retry."
        case .missingToken:
            return "The private upload token is missing. Update it in Settings and retry."
        case .invalidResponse:
            return "The configured Worker returned an invalid response."
        case .rejected(let reason):
            switch reason {
            case "unauthorized":
                return "The private upload token is no longer accepted. Paste the current token in Settings."
            case "upload_not_configured":
                return "The configured Worker does not have an upload token. Check the service URL."
            case "notion_schema_mismatch":
                return "The Notion databases need a schema repair before this recording can be routed."
            case "notion_access_denied":
                return "The Notion integration no longer has access to one or more routing databases."
            case "notion_target_missing":
                return "A configured Notion page or database could not be found."
            case "notion_rate_limited":
                return "Notion temporarily rate-limited routing. Wait briefly, then retry."
            default:
                return "The configured Worker rejected or could not complete the request."
            }
        case .keychain:
            return "The private credential could not be read from the iPhone Keychain."
        }
    }

    private static func safeTransferFailure(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Bluetooth disconnected") {
            return "Bluetooth disconnected during the encrypted transfer. Reconnect and retry."
        }
        if message.localizedCaseInsensitiveContains("command channel") {
            return "The recorder command channel was unavailable. Reconnect and retry."
        }
        return "The secure audio transfer could not be completed. Reconnect and retry."
    }

    private static func recordingListPage(from data: Data) -> RecordingListPage? {
        guard data.count >= 10,
              data[0] == 0x09,
              data[1] == 0xFF,
              data[5] == 0x1A || data[5] == 0x1B,
              data[6] == 0x0E
        else { return nil }

        let declaredLength = Int(data[7]) | (Int(data[8]) << 8)
        let checksum = data.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
        guard declaredLength == data.count, checksum == data.last else { return nil }

        let payload = Data(data[9 ..< data.count - 1])
        guard payload.count >= 2 else { return nil }
        let count = Int(payload[0]) | (Int(payload[1]) << 8)
        guard count <= 10 else { return nil }

        var result: [RecordingMetadata] = []
        var offset = 2
        let includesEndTime = data[5] == 0x1B
        let entrySize = includesEndTime ? 12 : 8
        for _ in 0 ..< count {
            guard payload.count >= offset + entrySize,
                  let fileID = littleEndianUInt32(payload, at: offset)
            else { return nil }
            let endTime = includesEndTime
                ? littleEndianUInt32(payload, at: offset + 4)
                : nil
            guard let size = littleEndianUInt32(payload, at: offset + (includesEndTime ? 8 : 4))
            else { return nil }
            if fileID > 0, size > 0 {
                result.append(RecordingMetadata(id: fileID, endTime: endTime, sizeBytes: size))
            }
            offset += entrySize
        }
        return RecordingListPage(
            commandType: data[5],
            fileCount: count,
            recordings: result.sorted { $0.id > $1.id }
        )
    }

    private func requestLegacyRecordingListIfNeeded(for data: Data) -> Bool {
        guard !metadataFallbackRequested,
              recordingListRequestID != nil,
              recordingListCommandType == 0x1B,
              recordingListPage == 0,
              recordingListEntries.isEmpty,
              data.count == 10,
              data[0] == 0x09,
              data[1] == 0xFF,
              data[5] == 0x1B,
              data[6] == 0x0E
        else { return false }

        metadataFallbackRequested = true
        recordingListCommandType = 0x1A
        recordingListPage = 0
        recordingListEntries.removeAll()
        recordingListState = "Trying compatibility inventory request…"
        if let requestID = recordingListRequestID {
            requestRecordingListPage(type: recordingListCommandType, page: 0, requestID: requestID)
        }
        record(
            kind: "command",
            summary: "New inventory request returned no entries; requested compatibility inventory",
            peripheral: connectedPeripheral,
            service: writeCharacteristic?.service?.uuid,
            characteristic: writeCharacteristic?.uuid
        )
        return true
    }

    private static func advertisementSummary(_ advertisement: [String: Any]) -> String {
        var parts: [String] = []
        if let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !services.isEmpty {
            parts.append("services: \(services.map(\.uuidString).joined(separator: ", "))")
        }
        if let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data {
            parts.append("manufacturer: \(manufacturer.count) bytes [\(hex(manufacturer.prefix(24)))]")
        }
        if let connectable = advertisement[CBAdvertisementDataIsConnectable] as? Bool {
            parts.append(connectable ? "connectable" : "not connectable")
        }
        return parts.joined(separator: " · ")
    }
}

extension BluetoothProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = switch central.state {
        case .poweredOn: "Powered on"
        case .poweredOff: "Powered off"
        case .unauthorized: "Permission denied"
        case .unsupported: "Unsupported"
        case .resetting: "Resetting"
        case .unknown: "Unknown"
        @unknown default: "Unknown"
        }
        record(kind: "bluetooth", summary: "Central state: \(bluetoothState)")
        if central.state == .poweredOn {
            reconnectSavedRecorderIfNeeded()
        } else {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
        }
        objectWillChange.send()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Unnamed device"
        let summary = Self.advertisementSummary(advertisementData)
        let device = DiscoveredDevice(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            advertisementSummary: summary
        )
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            devices.sort {
                let leftSoundcore = $0.name.localizedCaseInsensitiveContains("soundcore")
                let rightSoundcore = $1.name.localizedCaseInsensitiveContains("soundcore")
                return leftSoundcore == rightSoundcore ? $0.rssi > $1.rssi : leftSoundcore
            }
            record(
                kind: "advertisement",
                summary: "Discovered \(name) at \(RSSI) dBm. \(summary)",
                peripheral: peripheral
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        userRequestedDisconnect = false
        secureSession.reset()
        rememberRecorder(peripheral)
        connectedPeripheral = peripheral
        connectedPeripheralID = peripheral.identifier
        connectionState = "Connected to \(peripheral.name ?? "device")"
        characteristics.removeAll()
        writeCharacteristic = nil
        recordingListState = "Discovering recorder controls…"
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        record(kind: "connect", summary: connectionState, peripheral: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = "Reconnect interrupted — retrying…"
        record(
            kind: "error",
            summary: "Connection failed: \(error?.localizedDescription ?? "unknown error")",
            peripheral: peripheral
        )
        scheduleReconnect(to: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let shouldReconnect = !userRequestedDisconnect
        userRequestedDisconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        secureSession.reset()
        suspendTransferForReconnect()
        rememberRecorder(peripheral)
        connectedPeripheral = nil
        connectedPeripheralID = nil
        writeCharacteristic = nil
        recordingListRefreshWorkItem?.cancel()
        recordingListRefreshWorkItem = nil
        finishRecordingListRequest()
        recordingListState = "Connect to load recordings"
        connectionState = shouldReconnect ? "Reconnecting to Soundcore Work…" : "Disconnected"
        record(
            kind: error == nil ? "disconnect" : "error",
            summary: error?.localizedDescription ?? "Disconnected",
            peripheral: peripheral
        )
        if shouldReconnect { scheduleReconnect(to: peripheral) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripheral.delegate = self
            let device = DiscoveredDevice(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: peripheral.name ?? "Restored device",
                rssi: 0,
                advertisementSummary: "Restored by iOS"
            )
            if !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
            if peripheral.state == .connected {
                rememberRecorder(peripheral)
                connectedPeripheral = peripheral
                connectedPeripheralID = peripheral.identifier
                connectionState = "Restored connection to \(device.name)"
                peripheral.discoverServices(nil)
            }
        }
        record(kind: "restore", summary: "iOS restored \(restored.count) peripheral(s)")
    }
}

extension BluetoothProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            record(kind: "error", summary: "Service discovery failed: \(error.localizedDescription)", peripheral: peripheral)
            return
        }
        for service in peripheral.services ?? [] {
            record(
                kind: "service",
                summary: "Discovered service \(service.uuid.uuidString)",
                peripheral: peripheral,
                service: service.uuid
            )
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            record(
                kind: "error",
                summary: "Characteristic discovery failed: \(error.localizedDescription)",
                peripheral: peripheral,
                service: service.uuid
            )
            return
        }
        for characteristic in service.characteristics ?? [] {
            let propertyText = Self.propertiesDescription(characteristic.properties)
            let snapshot = CharacteristicSnapshot(
                id: "\(service.uuid.uuidString)/\(characteristic.uuid.uuidString)",
                serviceUUID: service.uuid.uuidString,
                characteristicUUID: characteristic.uuid.uuidString,
                properties: propertyText,
                isNotifying: characteristic.isNotifying
            )
            if let index = characteristics.firstIndex(where: { $0.id == snapshot.id }) {
                characteristics[index] = snapshot
            } else {
                characteristics.append(snapshot)
            }
            record(
                kind: "characteristic",
                summary: "Discovered \(characteristic.uuid.uuidString): \(propertyText)",
                peripheral: peripheral,
                service: service.uuid,
                characteristic: characteristic.uuid
            )
            if service.uuid.uuidString.uppercased() == "020CF5DA-0000-1000-8000-00805F9B34FB",
               characteristic.uuid.uuidString.uppercased() == "00007777-0000-1000-8000-00805F9B34FB",
               characteristic.properties.contains(.write)
                || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
                recordingListState = "Refreshing recordings…"
                connectionState = "Connected to \(peripheral.name ?? "Soundcore Work")"
                DispatchQueue.main.async { [weak self] in
                    self?.resumeReconnectFetchesIfReady()
                    self?.scheduleRecordingListRefresh()
                }
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        characteristics.sort { $0.id < $1.id }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            record(
                kind: "error",
                summary: "Value update failed: \(error.localizedDescription)",
                peripheral: peripheral,
                service: characteristic.service?.uuid,
                characteristic: characteristic.uuid
            )
            return
        }
        let data = characteristic.value ?? Data()
        let transferSummary = handleSecureTransferFrame(data)
        let decoded = Self.decodedD3200Event(data)
        let requestedFallback = requestLegacyRecordingListIfNeeded(for: data)
        if !requestedFallback, let page = Self.recordingListPage(from: data) {
            handleRecordingListPage(page)
        }
        if let decoded {
            if let state = decoded.state { recorderState = state }
            if let fileID = decoded.fileID { currentRecordingID = fileID }
            if let duration = decoded.duration { lastRecordingDuration = duration }
            if decoded.state == "Stopped", let fileID = decoded.fileID ?? currentRecordingID {
                automaticallyFetchStoppedRecording(fileID: fileID, duration: decoded.duration)
            }
        }
        if transferSummary == "" { return }
        record(
            kind: characteristic.isNotifying ? "notification" : "read",
            summary: transferSummary ?? decoded?.summary ?? "Received \(data.count) byte(s)",
            peripheral: peripheral,
            service: characteristic.service?.uuid,
            characteristic: characteristic.uuid,
            // Secure-session keys and audio never enter the diagnostic JSONL log.
            data: transferSummary == nil ? data : nil
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        record(
            kind: error == nil ? "subscription" : "error",
            summary: error?.localizedDescription ?? (characteristic.isNotifying ? "Subscribed to notifications" : "Notifications disabled"),
            peripheral: peripheral,
            service: characteristic.service?.uuid,
            characteristic: characteristic.uuid
        )
        if let index = characteristics.firstIndex(where: {
            $0.serviceUUID == characteristic.service?.uuid.uuidString
                && $0.characteristicUUID == characteristic.uuid.uuidString
        }) {
            let old = characteristics[index]
            characteristics[index] = CharacteristicSnapshot(
                id: old.id,
                serviceUUID: old.serviceUUID,
                characteristicUUID: old.characteristicUUID,
                properties: old.properties,
                isNotifying: characteristic.isNotifying
            )
        }
    }
}

private struct D3200Event {
    let summary: String
    let state: String?
    let fileID: UInt32?
    let duration: UInt32?
}
