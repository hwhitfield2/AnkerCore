import Foundation
import UserNotifications

final class ProcessingNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ProcessingNotifications()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    func started(_ recording: RecordingMetadata, reprocess: Bool) {
        deliver(
            title: reprocess ? "Re-processing recording" : "Processing recording",
            body: "AnkerCore started transcribing and sorting the recording from \(formattedDate(recording.recordedAt)).",
            recordingID: recording.id,
            state: "started"
        )
    }

    func completed(_ recording: RecordingMetadata, body: String) {
        deliver(
            title: "Recording processed",
            body: body,
            recordingID: recording.id,
            state: "completed"
        )
    }

    func needsAttention(_ recording: RecordingMetadata, body: String) {
        deliver(
            title: "Recording needs attention",
            body: body,
            recordingID: recording.id,
            state: "attention"
        )
    }

    private func deliver(
        title: String,
        body: String,
        recordingID: UInt32,
        state: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "ankercore-processing"
        content.userInfo = ["recordingID": recordingID]
        let request = UNNotificationRequest(
            identifier: "processing-\(state)-\(recordingID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
