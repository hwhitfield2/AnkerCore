import Foundation
import Security

struct AnkerCoreUploadResult: Decodable {
    struct Routed: Decodable {
        struct Destination: Decodable {
            let kind: String
            let destination: URL
            let database: URL
        }

        let kind: String?
        let area: String?
        let destination: URL?
        let database: URL?
        let ignored: Bool?
        let reason: String?
        let destinations: [Destination]?
        let itemCount: Int?

        private enum CodingKeys: String, CodingKey {
            case kind, area, destination, database, ignored, reason, destinations
            case itemCount = "item_count"
        }
    }

    struct Webhook: Decodable {
        let configured: Bool
        let delivered: Bool?
        let status: Int?
    }

    let ok: Bool
    let transcriptChars: Int?
    let source: URL?
    let routed: Routed?
    let webhook: Webhook?

    private enum CodingKeys: String, CodingKey {
        case ok
        case transcriptChars = "transcript_chars"
        case source
        case routed
        case webhook
    }
}

struct AnkerCoreTask: Identifiable, Decodable, Sendable {
    let id: String
    let title: String
    let status: String
    let due: String?
    let priority: String
    let area: String
    let owner: String
    let url: URL

    var dueDate: Date? {
        guard let due else { return nil }
        return ISO8601DateFormatter().date(from: due)
            ?? DateFormatter.ankercoreDay.date(from: String(due.prefix(10)))
    }
}

private struct AnkerCoreTaskList: Decodable {
    let ok: Bool
    let tasks: [AnkerCoreTask]
}

private struct AnkerCoreTaskMutation: Decodable {
    let ok: Bool
    let task: AnkerCoreTask
}

struct AnkerCoreRoutingDiagnostics: Decodable {
    let ok: Bool
    let issues: [String]
}

enum AnkerCoreUploadError: LocalizedError {
    case invalidEndpoint
    case missingToken
    case invalidResponse
    case rejected(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTPS service URL."
        case .missingToken: "Paste the private upload token first."
        case .invalidResponse: "The service returned an invalid response."
        case .rejected(let reason): "Processing failed: \(reason.replacingOccurrences(of: "_", with: " "))."
        case .keychain: "The private token could not be saved in Keychain."
        }
    }
}

struct AnkerCoreUploadClient {
    static let defaultEndpoint = ""

    private static let endpointKey = "ankercore.upload.endpoint"
    private static let legacyEndpointKey = "soundcore.upload.endpoint"
    private static let keychainService = "app.ankercore.credentials"
    private static let legacyKeychainService = "com.haydenwhitfield.SoundcoreProbe.upload"
    private static let keychainAccount = "worker-bearer-token"
    private static let webhookAccount = "optional-delivery-webhook"

    static var savedEndpoint: String {
        UserDefaults.standard.string(forKey: endpointKey)
            ?? UserDefaults.standard.string(forKey: legacyEndpointKey)
            ?? defaultEndpoint
    }

    static var hasToken: Bool { (try? readToken()) != nil }
    static var savedWebhookURL: String {
        (try? readSecret(account: webhookAccount))
            ?? (try? readSecret(account: webhookAccount, service: legacyKeychainService))
            ?? ""
    }

    static func saveConfiguration(endpoint: String, token: String, webhookURL: String = "") throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil else {
            throw AnkerCoreUploadError.invalidEndpoint
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            guard trimmedToken.count >= 32 else { throw AnkerCoreUploadError.missingToken }
            try storeSecret(trimmedToken, account: keychainAccount)
        } else if !hasToken {
            throw AnkerCoreUploadError.missingToken
        }
        let webhook = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if webhook.isEmpty {
            try deleteSecret(account: webhookAccount)
            try deleteSecret(account: webhookAccount, service: legacyKeychainService)
        } else {
            guard isValidPublicHTTPSURL(webhook) else { throw AnkerCoreUploadError.invalidEndpoint }
            try storeSecret(webhook, account: webhookAccount)
        }
        UserDefaults.standard.set(url.absoluteString, forKey: endpointKey)
    }

    static func clearToken() throws {
        try deleteSecret(account: keychainAccount)
        try deleteSecret(account: keychainAccount, service: legacyKeychainService)
    }

    private static func deleteSecret(account: String, service: String = keychainService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AnkerCoreUploadError.keychain(status)
        }
    }

    func upload(fileURL: URL, recording: RecordingMetadata, reprocess: Bool = false) async throws -> AnkerCoreUploadResult {
        guard let endpoint = URL(string: Self.savedEndpoint), endpoint.scheme == "https" else {
            throw AnkerCoreUploadError.invalidEndpoint
        }
        guard let token = try Self.readToken() else { throw AnkerCoreUploadError.missingToken }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("audio/ogg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(recording.id), forHTTPHeaderField: "X-AnkerCore-File-ID")
        request.setValue(ISO8601DateFormatter().string(from: recording.recordedAt), forHTTPHeaderField: "X-AnkerCore-Recorded-At")
        if reprocess { request.setValue("true", forHTTPHeaderField: "X-AnkerCore-Reprocess") }
        let webhookURL = Self.savedWebhookURL
        if !webhookURL.isEmpty { request.setValue(webhookURL, forHTTPHeaderField: "X-AnkerCore-Webhook") }

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else { throw AnkerCoreUploadError.invalidResponse }
        if (200 ..< 300).contains(http.statusCode) {
            return try JSONDecoder().decode(AnkerCoreUploadResult.self, from: data)
        }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw AnkerCoreUploadError.rejected(reason ?? "HTTP \(http.statusCode)")
    }

    func fetchOpenTasks() async throws -> [AnkerCoreTask] {
        let request = try authorizedRequest(path: "/tasks", method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnkerCoreUploadError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AnkerCoreUploadError.rejected(reason ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(AnkerCoreTaskList.self, from: data).tasks
    }

    func completeTask(id: String) async throws -> AnkerCoreTask {
        let safeID = id.filter { $0.isHexDigit || $0 == "-" }
        guard safeID.count == id.count, (32 ... 36).contains(safeID.count) else { throw AnkerCoreUploadError.invalidResponse }
        let request = try authorizedRequest(path: "/tasks/\(safeID)/complete", method: "POST")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw AnkerCoreUploadError.rejected("task_update_failed")
        }
        return try JSONDecoder().decode(AnkerCoreTaskMutation.self, from: data).task
    }

    func routingDiagnostics() async throws -> AnkerCoreRoutingDiagnostics {
        let request = try authorizedRequest(path: "/diagnostics/routing", method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnkerCoreUploadError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AnkerCoreUploadError.rejected(reason ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(AnkerCoreRoutingDiagnostics.self, from: data)
    }

    @available(iOS 26.0, *)
    func routeTranscript(
        _ transcript: String,
        analysis: OnDeviceAnalysis?,
        recording: RecordingMetadata,
        reprocess: Bool = false
    ) async throws -> AnkerCoreUploadResult {
        guard let audioEndpoint = URL(string: Self.savedEndpoint), audioEndpoint.scheme == "https" else {
            throw AnkerCoreUploadError.invalidEndpoint
        }
        guard let token = try Self.readToken() else { throw AnkerCoreUploadError.missingToken }
        var components = URLComponents(url: audioEndpoint, resolvingAgainstBaseURL: false)
        components?.path = "/transcript"
        components?.query = nil
        components?.fragment = nil
        guard let endpoint = components?.url else { throw AnkerCoreUploadError.invalidEndpoint }

        var payload: [String: Any] = [
            "file_id": String(recording.id),
            "recorded_at": ISO8601DateFormatter().string(from: recording.recordedAt),
            "transcript": String(transcript.prefix(30_000)),
            "reprocess": reprocess,
        ]
        let webhookURL = Self.savedWebhookURL
        if !webhookURL.isEmpty { payload["webhook_url"] = webhookURL }
        if let analysis {
            payload["analysis"] = [
                "area": analysis.area,
                "area_confidence": analysis.areaConfidence,
                "summary": analysis.summary,
                "project": analysis.project,
                "client": analysis.client,
                "people": analysis.people,
                "meeting": analysis.hasMeeting ? [
                    "title": analysis.meetingTitle,
                    "participants": analysis.participants,
                    "decisions": analysis.decisions,
                    "open_questions": analysis.openQuestions,
                    "follow_up": analysis.followUp,
                ] : NSNull(),
                "tasks": analysis.tasks.map { [
                    "title": $0.title,
                    "owner": $0.owner,
                    "due_date": $0.dueDate,
                    "priority": $0.priority,
                    "summary": $0.summary,
                    "source_quote": $0.sourceQuote,
                ] },
                "ideas": analysis.ideas.map { [
                    "title": $0.title,
                    "topic": $0.topic,
                    "summary": $0.summary,
                    "why_it_matters": $0.whyItMatters,
                    "next_experiment": $0.nextExperiment,
                ] },
            ]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data: data, response: response)
    }

    private func decode(data: Data, response: URLResponse) throws -> AnkerCoreUploadResult {
        guard let http = response as? HTTPURLResponse else { throw AnkerCoreUploadError.invalidResponse }
        if (200 ..< 300).contains(http.statusCode) {
            return try JSONDecoder().decode(AnkerCoreUploadResult.self, from: data)
        }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw AnkerCoreUploadError.rejected(reason ?? "HTTP \(http.statusCode)")
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        guard let base = URL(string: Self.savedEndpoint), base.scheme == "https" else { throw AnkerCoreUploadError.invalidEndpoint }
        guard let token = try Self.readToken() else { throw AnkerCoreUploadError.missingToken }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else { throw AnkerCoreUploadError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private static func storeSecret(_ value: String, account: String) throws {
        try deleteSecret(account: account)
        try deleteSecret(account: account, service: legacyKeychainService)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AnkerCoreUploadError.keychain(status) }
    }

    private static func readToken() throws -> String? {
        if let current = try readSecret(account: keychainAccount) { return current }
        return try readSecret(account: keychainAccount, service: legacyKeychainService)
    }

    private static func readSecret(account: String, service: String = keychainService) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AnkerCoreUploadError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isValidPublicHTTPSURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443
        else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        return !host.contains(":") && host.split(separator: ".").contains(where: { Int($0) == nil })
    }
}

private extension DateFormatter {
    static let ankercoreDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
