import SwiftUI
import WidgetKit

private struct AnkerCoreWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AnkerCoreWidgetSnapshot
}

private struct AnkerCoreWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AnkerCoreWidgetEntry {
        AnkerCoreWidgetEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (AnkerCoreWidgetEntry) -> Void) {
        completion(AnkerCoreWidgetEntry(date: Date(), snapshot: context.isPreview ? .preview : AnkerCoreWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AnkerCoreWidgetEntry>) -> Void) {
        let entry = AnkerCoreWidgetEntry(date: Date(), snapshot: AnkerCoreWidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private enum WidgetPalette {
    static let background = Color(red: 0.025, green: 0.055, blue: 0.065)
    static let surface = Color(red: 0.055, green: 0.095, blue: 0.105)
    static let mint = Color(red: 0.30, green: 0.88, blue: 0.65)
    static let sky = Color(red: 0.30, green: 0.70, blue: 1.00)
    static let coral = Color(red: 1.00, green: 0.36, blue: 0.27)
    static let secondary = Color(red: 0.58, green: 0.66, blue: 0.67)
}

private struct AnkerCoreWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AnkerCoreWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: compactView
            case .systemLarge: dashboard(recordingLimit: 5, taskLimit: 5)
            default: dashboard(recordingLimit: 3, taskLimit: 3)
            }
        }
        .containerBackground(WidgetPalette.background, for: .widget)
        .privacySensitive()
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let recording = entry.snapshot.recordings.first {
                Image(systemName: stateIcon(recording.state))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(stateColor(recording.state))
                Text(recording.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(recording.recordedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(WidgetPalette.secondary)
            } else {
                Spacer()
                Label("No recordings yet", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetPalette.secondary)
            }
            Spacer(minLength: 0)
            Label("\(entry.snapshot.tasks.count) open", systemImage: "checklist")
                .font(.caption.weight(.bold))
                .foregroundStyle(entry.snapshot.tasks.isEmpty ? WidgetPalette.mint : WidgetPalette.sky)
        }
    }

    private func dashboard(recordingLimit: Int, taskLimit: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            column(title: "RECORDINGS", icon: "waveform", empty: "No processing history") {
                ForEach(entry.snapshot.recordings.prefix(recordingLimit)) { recording in
                    if let destination = recording.destination {
                        Link(destination: destination) { recordingRow(recording) }
                    } else {
                        recordingRow(recording)
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.09))
            column(title: "TASKS", icon: "checklist", empty: "Nothing open") {
                ForEach(entry.snapshot.tasks.prefix(taskLimit)) { task in
                    Link(destination: task.url) { taskRow(task) }
                }
            }
        }
        .overlay(alignment: .topLeading) { header.offset(y: -2) }
        .padding(.top, 27)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .foregroundStyle(WidgetPalette.mint)
            Text("ANKERCORE")
                .font(.caption2.weight(.black))
                .tracking(1.2)
                .foregroundStyle(.white)
            Spacer()
            if entry.snapshot.updatedAt != .distantPast {
                Text(entry.snapshot.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(WidgetPalette.secondary)
            }
        }
    }

    private func column<Content: View>(title: String, icon: String, empty: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.black))
                .foregroundStyle(WidgetPalette.secondary)
            if title == "RECORDINGS", entry.snapshot.recordings.isEmpty {
                emptyState(empty, icon: icon)
            } else if title == "TASKS", entry.snapshot.tasks.isEmpty {
                emptyState(empty, icon: icon)
            } else {
                content()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordingRow(_ recording: AnkerCoreWidgetRecording) -> some View {
        HStack(spacing: 8) {
            Image(systemName: stateIcon(recording.state))
                .font(.caption.weight(.bold))
                .foregroundStyle(stateColor(recording.state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(recording.stage) · \(recording.recordedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func taskRow(_ task: AnkerCoreWidgetTask) -> some View {
        HStack(spacing: 8) {
            Circle()
                .stroke(priorityColor(task.priority), lineWidth: 1.5)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(taskSubtitle(task))
                    .font(.caption2)
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(WidgetPalette.secondary)
            .padding(.top, 8)
    }

    private func stateIcon(_ state: String) -> String {
        switch state {
        case "succeeded": "checkmark.circle.fill"
        case "failed": "exclamationmark.octagon.fill"
        case "attention": "exclamationmark.triangle.fill"
        case "running": "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        default: "clock.fill"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "succeeded": WidgetPalette.mint
        case "failed": WidgetPalette.coral
        case "attention": .orange
        case "running": WidgetPalette.sky
        default: WidgetPalette.secondary
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "Urgent": WidgetPalette.coral
        case "High": .orange
        case "Low": WidgetPalette.secondary
        default: WidgetPalette.sky
        }
    }

    private func taskSubtitle(_ task: AnkerCoreWidgetTask) -> String {
        if let due = task.due { return "\(task.priority) · due \(due.formatted(date: .abbreviated, time: .omitted))" }
        return "\(task.priority) · \(task.area)"
    }
}

private extension AnkerCoreWidgetSnapshot {
    static var preview: Self {
        AnkerCoreWidgetSnapshot(
            updatedAt: Date(),
            recordings: [
                AnkerCoreWidgetRecording(id: 1, recordedAt: Date().addingTimeInterval(-240), stage: "Notion routing", state: "succeeded", title: "Processing complete", destination: nil),
                AnkerCoreWidgetRecording(id: 2, recordedAt: Date().addingTimeInterval(-900), stage: "Transcription", state: "running", title: "On-device transcription", destination: nil),
            ],
            tasks: [
                AnkerCoreWidgetTask(id: "1", title: "Wire up application dashboards", due: Date().addingTimeInterval(86_400), priority: "High", area: "Work", url: URL(string: "ankercore://tasks")!),
                AnkerCoreWidgetTask(id: "2", title: "Review meeting follow-up", due: nil, priority: "Medium", area: "Work", url: URL(string: "ankercore://tasks")!),
            ]
        )
    }
}

struct AnkerCoreStatusWidget: Widget {
    let kind = AnkerCoreWidgetStore.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AnkerCoreWidgetProvider()) { entry in
            AnkerCoreWidgetView(entry: entry)
        }
        .configurationDisplayName("AnkerCore Relay")
        .description("Recent recordings, processing status, and open tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct AnkerCoreWidgetBundle: WidgetBundle {
    var body: some Widget {
        AnkerCoreStatusWidget()
    }
}
