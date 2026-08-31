import Foundation

enum RecordingProcessingStage: String, Codable {
    case capture
    case fetch
    case transcription
    case classification
    case routing
    case delivery
}

enum RecordingProcessingState: String, Codable {
    case running
    case succeeded
    case failed
    case attention
    case waiting
}

struct RecordingProcessingLink: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let url: URL

    init(title: String, url: URL) {
        id = UUID()
        self.title = String(title.prefix(80))
        self.url = url
    }
}

struct RecordingProcessingEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let stage: RecordingProcessingStage
    let state: RecordingProcessingState
    let title: String
    let detail: String
    let links: [RecordingProcessingLink]

    init(
        timestamp: Date = Date(),
        stage: RecordingProcessingStage,
        state: RecordingProcessingState,
        title: String,
        detail: String,
        links: [RecordingProcessingLink] = []
    ) {
        id = UUID()
        self.timestamp = timestamp
        self.stage = stage
        self.state = state
        self.title = String(title.prefix(100))
        self.detail = String(detail.prefix(240))
        self.links = Array(links.prefix(20))
    }
}

struct RecordingProcessingLog: Identifiable, Codable, Hashable {
    let id: UInt32
    var recordedAt: Date
    var events: [RecordingProcessingEvent]

    var latestEvent: RecordingProcessingEvent? { events.last }
    var summary: String { latestEvent?.title ?? "Not processed on this iPhone" }
    var state: RecordingProcessingState { latestEvent?.state ?? .waiting }
}

enum ProcessingLogPersistence {
    private static let maximumLogs = 100
    private static let fileName = "recording-processing-history.json"

    static func load() -> [UInt32: RecordingProcessingLog] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode([RecordingProcessingLog].self, from: data)
        else { return [:] }

        var logs: [UInt32: RecordingProcessingLog] = [:]
        for log in stored { logs[log.id] = log }
        return logs
    }

    static func save(_ logs: [UInt32: RecordingProcessingLog]) {
        let stored = Array(logs.values.sorted { $0.recordedAt > $1.recordedAt }.prefix(maximumLogs))
        guard let data = try? encoder.encode(stored) else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = fileURL
            try? protectedURL.setResourceValues(values)
        } catch {
            // Processing history is useful but must never interrupt recording delivery.
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnkerCore", isDirectory: true)
    }

    private static var fileURL: URL { directoryURL.appendingPathComponent(fileName) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
