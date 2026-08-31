import Foundation
import WidgetKit

struct AnkerCoreWidgetRecording: Codable, Hashable, Identifiable {
    let id: UInt32
    let recordedAt: Date
    let stage: String
    let state: String
    let title: String
    let destination: URL?
}

struct AnkerCoreWidgetTask: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let due: Date?
    let priority: String
    let area: String
    let url: URL
}

struct AnkerCoreWidgetSnapshot: Codable, Hashable {
    let updatedAt: Date
    let recordings: [AnkerCoreWidgetRecording]
    let tasks: [AnkerCoreWidgetTask]

    static let empty = AnkerCoreWidgetSnapshot(updatedAt: .distantPast, recordings: [], tasks: [])
}

enum AnkerCoreWidgetStore {
    static let kind = "AnkerCoreStatusWidget"
    static let appGroup = "group.com.ankercore.app"
    private static let fileName = "widget-snapshot.json"

    static func load() -> AnkerCoreWidgetSnapshot {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              data.count <= 256_000,
              let snapshot = try? decoder.decode(AnkerCoreWidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    static func save(_ snapshot: AnkerCoreWidgetSnapshot) {
        guard let fileURL,
              snapshot.recordings.count <= 20,
              snapshot.tasks.count <= 20,
              let data = try? encoder.encode(snapshot),
              data.count <= 256_000
        else { return }

        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = fileURL
            try? protectedURL.setResourceValues(values)
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } catch {
            // A widget refresh must never interrupt recording or routing.
        }
    }

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

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
