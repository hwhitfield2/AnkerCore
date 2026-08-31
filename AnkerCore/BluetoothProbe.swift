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
    @Published private(set) var transferState = "No audio transfer active"
    @Published private(set) var transferProgress = 0.0
    @Published private(set) var downloadedRecordings: [UInt32: URL] = [:]
    @Published private(set) var uploadState = "Paste the private token once to enable automatic processing"
    @Published private(set) var uploadEndpoint = AnkerCoreUploadClient.savedEndpoint
    @Published private(set) var uploadConfigured = AnkerCoreUploadClient.hasToken
    @Published private(set) var lastDestinationURL: URL?
    @Published private(set) var processingMode = "On-device preferred"

    var canScan: Bool { central?.state == .poweredOn }
    var canLoadRecordings: Bool { writeCharacteristic != nil }
    var canFetchRecording: Bool { writeCharacteristic != nil && transferHandle == nil }

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var metadataFallbackRequested = false
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
        connectionState = "Connecting to \(device.name)…"
        device.peripheral.delegate = self
        central.connect(device.peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        record(
            kind: "connect",
            summary: "Requested connection to \(device.name)",
            peripheral: device.peripheral
        )
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        record(kind: "disconnect", summary: "Requested disconnect", peripheral: peripheral)
    }

    func loadRecordings() {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic,
              characteristic.service?.uuid.uuidString.uppercased()
                == "020CF5DA-0000-1000-8000-00805F9B34FB",
              characteristic.uuid.uuidString.uppercased()
                == "00007777-0000-1000-8000-00805F9B34FB"
        else {
            recordingListState = "Recorder command channel is not ready"
            return
        }

        metadataFallbackRequested = false
        // Whitelisted, non-destructive command: list recording metadata, page zero.
        let command = Self.d3200Command(type: 0x1B, id: 0x0E, payload: Data([0x00, 0x00]))
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        peripheral.writeValue(command, for: characteristic, type: writeType)
        recordingListState = "Loading recording list…"
        record(
            kind: "command",
            summary: "Requested recording metadata (page 1)",
            peripheral: peripheral,
            service: characteristic.service?.uuid,
            characteristic: characteristic.uuid
        )
    }

    func fetchRecording(_ recording: RecordingMetadata) {
        guard transferHandle == nil else {
            transferState = "Another transfer is already active"
            return
        }
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
                failTransfer("Recorder command channel is not ready")
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
        } catch {
            uploadState = error.localizedDescription
        }
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
            failTransfer("Recorder command channel is not ready")
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

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnkerCore Recordings", isDirectory: true)
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
        } catch {
            // Preserve the decrypted raw file if container creation ever fails.
            transferState = "Saved raw audio; playable conversion failed"
        }
        transferProgress = 1
        downloadedRecordings[target.id] = finalURL
        if finalURL.pathExtension == "ogg" {
            transferState = "Saved playable audio securely on this iPhone"
            uploadRecording(finalURL, recording: target)
        }
        record(kind: "secure-transfer", summary: "Saved playable file \(target.id) locally; audio omitted from capture")
        pendingTransfer = nil
        transferURL = nil
        transferFileKey = nil
        transferNonce = nil
    }

    private func uploadRecording(_ fileURL: URL, recording: RecordingMetadata) {
        guard uploadConfigured else {
            uploadState = "Saved locally — add the private token to process automatically"
            return
        }
        uploadState = "Transcribing on this iPhone…"
        processingMode = "On-device preferred"
        lastDestinationURL = nil
        Task {
            let transcript: String
            do {
                transcript = try await onDeviceProcessor.transcribe(fileURL: fileURL)
            } catch {
                await MainActor.run {
                    uploadState = "Local speech unavailable — using cloud transcription…"
                    processingMode = "Cloud transcription fallback"
                }
                do {
                    let result = try await uploadClient.upload(fileURL: fileURL, recording: recording)
                    await applyUploadResult(result, mode: "Cloud transcription fallback")
                } catch {
                    await MainActor.run { uploadState = error.localizedDescription }
                }
                return
            }

            if #available(iOS 26.0, *) {
                await routeLocallyTranscribed(transcript, recording: recording)
            }
        }
    }

    @available(iOS 26.0, *)
    private func routeLocallyTranscribed(_ transcript: String, recording: RecordingMetadata) async {
        var analysis: OnDeviceAnalysis?
        await MainActor.run { uploadState = "Sorting on this iPhone…" }
        do {
            analysis = try await onDeviceProcessor.classify(transcript: transcript, recordedAt: recording.recordedAt)
        } catch {
            await MainActor.run {
                uploadState = "Using transcript-only cloud sorting…"
                processingMode = "Local transcript · cloud sorting"
            }
        }

        do {
            let result = try await uploadClient.routeTranscript(transcript, analysis: analysis, recording: recording)
            await applyUploadResult(
                result,
                mode: analysis == nil ? "Local transcript · cloud sorting" : "Fully on-device AI"
            )
        } catch {
            // The local transcript is already available. Do not upload audio merely because delivery failed.
            await MainActor.run { uploadState = error.localizedDescription }
        }
    }

    @MainActor
    private func applyUploadResult(_ result: AnkerCoreUploadResult, mode: String) {
        processingMode = mode
        let webhookSuffix: String
        if result.webhook?.configured == true {
            webhookSuffix = result.webhook?.delivered == true ? " · webhook sent" : " · webhook failed"
        } else {
            webhookSuffix = ""
        }
        if let destination = result.routed?.destination {
            lastDestinationURL = destination
            uploadState = "Processed as \(result.routed?.kind ?? "item") · \(result.routed?.area ?? "Needs Review")\(webhookSuffix)"
        } else if result.routed?.reason == "already_routed" {
            lastDestinationURL = result.source
            uploadState = "This recording was already processed\(webhookSuffix)"
        } else {
            lastDestinationURL = result.source
            uploadState = "Transcribed; open Notion to review routing\(webhookSuffix)"
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if self.canFetchRecording {
                self.fetchRecording(metadata)
            } else {
                self.uploadState = "Could not fetch automatically; use Fetch Audio after reconnecting"
            }
        }
    }

    private func failTransfer(_ message: String) {
        try? transferHandle?.close()
        transferHandle = nil
        if let transferURL { try? FileManager.default.removeItem(at: transferURL) }
        transferState = "Transfer failed: \(message)"
        transferProgress = 0
        pendingTransfer = nil
        transferURL = nil
        transferFileKey = nil
        transferNonce = nil
    }

    private static func recordingList(from data: Data) -> [RecordingMetadata]? {
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
        guard payload.count >= 2 else { return [] }
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
        return result.sorted { $0.id > $1.id }
    }

    private func requestLegacyRecordingListIfNeeded(for data: Data) -> Bool {
        guard !metadataFallbackRequested,
              data.count == 10,
              data[0] == 0x09,
              data[1] == 0xFF,
              data[5] == 0x1B,
              data[6] == 0x0E,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic
        else { return false }

        metadataFallbackRequested = true
        let fallback = Self.d3200Command(type: 0x1A, id: 0x0E, payload: Data([0x00, 0x00]))
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        peripheral.writeValue(fallback, for: characteristic, type: writeType)
        recordingListState = "Trying compatibility inventory request…"
        record(
            kind: "command",
            summary: "New inventory request returned no entries; requested compatibility inventory",
            peripheral: peripheral,
            service: characteristic.service?.uuid,
            characteristic: characteristic.uuid
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
        connectionState = "Connection failed"
        record(
            kind: "error",
            summary: "Connection failed: \(error?.localizedDescription ?? "unknown error")",
            peripheral: peripheral
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if transferHandle != nil { failTransfer("Bluetooth disconnected") }
        connectedPeripheral = nil
        connectedPeripheralID = nil
        writeCharacteristic = nil
        recordingListState = "Connect to load recordings"
        connectionState = "Disconnected"
        record(
            kind: error == nil ? "disconnect" : "error",
            summary: error?.localizedDescription ?? "Disconnected",
            peripheral: peripheral
        )
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
                recordingListState = "Ready to load recordings"
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
        if !requestedFallback, let loadedRecordings = Self.recordingList(from: data) {
            recordings = loadedRecordings
            recordingListState = loadedRecordings.isEmpty
                ? "No recordings found"
                : "Loaded \(loadedRecordings.count) recording(s)"
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
