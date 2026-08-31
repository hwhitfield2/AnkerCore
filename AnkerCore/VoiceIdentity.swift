import Foundation
import FluidAudio

struct VoiceProfile: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    let embedding: [Float]
    let createdAt: Date
    let consentConfirmed: Bool
}

struct TimedTranscriptPiece: Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum VoiceIdentityError: LocalizedError {
    case consentRequired
    case invalidName
    case sampleTooShort
    case invalidEmbedding

    var errorDescription: String? {
        switch self {
        case .consentRequired: "Confirm that this person consented to voice identification."
        case .invalidName: "Enter a name between 1 and 50 characters."
        case .sampleTooShort: "Use a clean recording with at least five seconds of only this speaker."
        case .invalidEmbedding: "A reliable voice signature could not be created from that recording."
        }
    }
}

actor VoiceIdentityEngine {
    static let shared = VoiceIdentityEngine()

    private var cachedDiarizer: DiarizerManager?

    func profiles() throws -> [VoiceProfile] {
        let url = try profileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: url))
    }

    func enroll(name: String, from fileURL: URL, consentConfirmed: Bool) async throws -> VoiceProfile {
        guard consentConfirmed else { throw VoiceIdentityError.consentRequired }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 50).contains(cleanName.count) else { throw VoiceIdentityError.invalidName }

        let samples = try AudioConverter().resampleAudioFile(fileURL)
        guard samples.count >= 5 * 16_000 else { throw VoiceIdentityError.sampleTooShort }
        let cleanSample = Array(samples.prefix(30 * 16_000))
        let diarizer = try await manager()
        let embedding = try diarizer.extractSpeakerEmbedding(from: cleanSample)
        guard embedding.count == SpeakerManager.embeddingSize,
              embedding.allSatisfy(\.isFinite),
              diarizer.validateEmbedding(embedding)
        else { throw VoiceIdentityError.invalidEmbedding }

        var saved = try profiles()
        saved.removeAll { $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }
        let profile = VoiceProfile(
            id: UUID().uuidString,
            name: cleanName,
            embedding: embedding,
            createdAt: Date(),
            consentConfirmed: true
        )
        saved.append(profile)
        try persist(saved)
        return profile
    }

    func delete(id: String) throws {
        var saved = try profiles()
        saved.removeAll { $0.id == id }
        try persist(saved)
    }

    func label(_ pieces: [TimedTranscriptPiece], audioURL: URL) async throws -> String {
        guard !pieces.isEmpty else { return "" }
        let saved = try profiles()
        guard !saved.isEmpty else { return pieces.map(\.text).joined(separator: " ") }
        let diarizer = try await manager()
        diarizer.initializeKnownSpeakers(saved.map {
            Speaker(id: $0.id, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
        })
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        let result = try diarizer.performCompleteDiarization(samples)
        guard !result.segments.isEmpty else { return pieces.map(\.text).joined(separator: " ") }

        let known = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.name) })
        var unknown: [String: String] = [:]
        var nextUnknown = 1
        var lines: [(speaker: String, text: String)] = []

        for piece in pieces {
            let match = result.segments.max { overlap($0, piece) < overlap($1, piece) }
            let speakerID = match?.speakerId ?? "unknown"
            let speaker: String
            if let name = known[speakerID] {
                speaker = name
            } else if let existing = unknown[speakerID] {
                speaker = existing
            } else {
                speaker = "Speaker \(nextUnknown)"
                unknown[speakerID] = speaker
                nextUnknown += 1
            }
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if lines.last?.speaker == speaker {
                lines[lines.count - 1].text += " \(text)"
            } else {
                lines.append((speaker, text))
            }
        }
        return lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func overlap(_ segment: TimedSpeakerSegment, _ piece: TimedTranscriptPiece) -> Double {
        max(0, min(Double(segment.endTimeSeconds), piece.end) - max(Double(segment.startTimeSeconds), piece.start))
    }

    private func manager() async throws -> DiarizerManager {
        if let cachedDiarizer { return cachedDiarizer }
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7, minSpeechDuration: 1.0))
        manager.initialize(models: models)
        cachedDiarizer = manager
        return manager
    }

    private func persist(_ profiles: [VoiceProfile]) throws {
        let url = try profileURL()
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try protectedURL.setResourceValues(values)
    }

    private func profileURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AnkerCore", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return root.appendingPathComponent("VoiceProfiles.json", isDirectory: false)
    }
}
