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
    static let background = Color(red: 0.018, green: 0.039, blue: 0.046)
    static let surface = Color(red: 0.055, green: 0.090, blue: 0.098)
    static let border = Color.white.opacity(0.075)
    static let mint = Color(red: 0.29, green: 0.90, blue: 0.66)
    static let sky = Color(red: 0.30, green: 0.70, blue: 1.00)
    static let coral = Color(red: 1.00, green: 0.36, blue: 0.27)
    static let amber = Color(red: 1.00, green: 0.59, blue: 0.18)
    static let secondary = Color(red: 0.59, green: 0.67, blue: 0.68)
}

private struct AnkerCoreWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AnkerCoreWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                compactView
            case .systemLarge:
                largeDashboard
            default:
                mediumDashboard
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.075, blue: 0.082), WidgetPalette.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .privacySensitive()
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader(showSubtitle: false)
            Spacer(minLength: 10)
            if let recording = entry.snapshot.recordings.first {
                HStack(alignment: .center, spacing: 10) {
                    stateSymbol(recording.state, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.state == "succeeded" ? "Ready" : recording.title)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(recording.stage) · \(ageLabel(recording.recordedAt))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WidgetPalette.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Label("Ready to capture", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetPalette.secondary)
            }
            Spacer(minLength: 10)
            HStack {
                Label("\(entry.snapshot.tasks.count) open", systemImage: "checklist")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(entry.snapshot.tasks.isEmpty ? WidgetPalette.mint : WidgetPalette.sky)
                Spacer()
                Text(updatedLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetPalette.secondary)
            }
        }
        .padding(15)
    }

    private var mediumDashboard: some View {
        VStack(spacing: 10) {
            brandHeader(showSubtitle: true)
            HStack(alignment: .top, spacing: 12) {
                compactColumn(title: "RECORDINGS", count: entry.snapshot.recordings.count, icon: "waveform") {
                    ForEach(entry.snapshot.recordings.prefix(2)) { recording in
                        recordingLink(recording, dense: true)
                    }
                }
                Rectangle()
                    .fill(WidgetPalette.border)
                    .frame(width: 1)
                compactColumn(title: "OPEN TASKS", count: entry.snapshot.tasks.count, icon: "checklist") {
                    ForEach(entry.snapshot.tasks.prefix(2)) { task in
                        Link(destination: task.url) { taskRow(task, dense: true) }
                    }
                }
            }
        }
        .padding(14)
    }

    private var largeDashboard: some View {
        VStack(spacing: 11) {
            brandHeader(showSubtitle: true)
            dashboardSection(
                title: "RECENT RECORDINGS",
                count: entry.snapshot.recordings.count,
                icon: "waveform",
                empty: "No processing history"
            ) {
                ForEach(entry.snapshot.recordings.prefix(3)) { recording in
                    recordingLink(recording, dense: true)
                }
            }
            dashboardSection(
                title: "OPEN TASKS",
                count: entry.snapshot.tasks.count,
                icon: "checklist",
                empty: "Nothing open"
            ) {
                ForEach(entry.snapshot.tasks.prefix(3)) { task in
                    Link(destination: task.url) { taskRow(task, dense: true) }
                }
            }
        }
        .padding(15)
    }

    private func brandHeader(showSubtitle: Bool) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(WidgetPalette.mint)
                Image(systemName: "waveform.path.ecg")
                    .font(.caption.weight(.black))
                    .foregroundStyle(WidgetPalette.background)
            }
            .frame(width: 29, height: 29)
            VStack(alignment: .leading, spacing: -1) {
                Text("AnkerCore")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
                if showSubtitle {
                    Text("RELAY")
                        .font(.system(size: 8, weight: .black))
                        .tracking(1.4)
                        .foregroundStyle(WidgetPalette.mint)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(WidgetPalette.mint)
                    .frame(width: 6, height: 6)
                Text(updatedLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetPalette.secondary)
            }
        }
        .frame(height: 30)
    }

    private func compactColumn<Content: View>(
        title: String,
        count: Int,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title, count: count, icon: icon)
            if count == 0 {
                emptyState(title == "OPEN TASKS" ? "Nothing open" : "No history", icon: icon)
            } else {
                content()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dashboardSection<Content: View>(
        title: String,
        count: Int,
        icon: String,
        empty: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title, count: count, icon: icon)
            if count == 0 {
                emptyState(empty, icon: icon)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(WidgetPalette.mint)
            Text(title)
                .font(.caption2.weight(.black))
                .tracking(0.7)
                .foregroundStyle(WidgetPalette.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2.weight(.black))
                .foregroundStyle(WidgetPalette.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(WidgetPalette.surface, in: Capsule())
        }
    }

    @ViewBuilder
    private func recordingLink(_ recording: AnkerCoreWidgetRecording, dense: Bool) -> some View {
        if let destination = recording.destination {
            Link(destination: destination) { recordingRow(recording, dense: dense) }
        } else {
            recordingRow(recording, dense: dense)
        }
    }

    private func recordingRow(_ recording: AnkerCoreWidgetRecording, dense: Bool) -> some View {
        HStack(spacing: 9) {
            stateSymbol(recording.state, size: dense ? 27 : 31)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font((dense ? Font.caption : Font.subheadline).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(recording.stage) · \(ageLabel(recording.recordedAt))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !dense {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetPalette.secondary.opacity(0.65))
            }
        }
        .padding(.horizontal, dense ? 7 : 10)
        .padding(.vertical, dense ? 5 : 7)
        .background(WidgetPalette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(WidgetPalette.border, lineWidth: 0.7)
        }
    }

    private func taskRow(_ task: AnkerCoreWidgetTask, dense: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .stroke(priorityColor(task.priority), lineWidth: 2)
                .frame(width: dense ? 17 : 19, height: dense ? 17 : 19)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font((dense ? Font.caption : Font.subheadline).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(taskSubtitle(task))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !dense {
                Text(task.priority.uppercased())
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(priorityColor(task.priority))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(priorityColor(task.priority).opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, dense ? 7 : 10)
        .padding(.vertical, dense ? 5 : 7)
        .background(WidgetPalette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(WidgetPalette.border, lineWidth: 0.7)
        }
    }

    private func stateSymbol(_ state: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(stateColor(state).opacity(0.14))
            Image(systemName: stateIcon(state))
                .font(.caption.weight(.black))
                .foregroundStyle(stateColor(state))
        }
        .frame(width: size, height: size)
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(WidgetPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
            .padding(.horizontal, 10)
            .background(WidgetPalette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stateIcon(_ state: String) -> String {
        switch state {
        case "succeeded": "checkmark"
        case "failed": "exclamationmark"
        case "attention": "exclamationmark.triangle.fill"
        case "running": "arrow.trianglehead.2.clockwise.rotate.90"
        default: "clock.fill"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "succeeded": WidgetPalette.mint
        case "failed": WidgetPalette.coral
        case "attention": WidgetPalette.amber
        case "running": WidgetPalette.sky
        default: WidgetPalette.secondary
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "Urgent": WidgetPalette.coral
        case "High": WidgetPalette.amber
        case "Low": WidgetPalette.secondary
        default: WidgetPalette.sky
        }
    }

    private var updatedLabel: String {
        guard entry.snapshot.updatedAt != .distantPast else { return "WAITING" }
        return "UPDATED \(ageLabel(entry.snapshot.updatedAt).uppercased())"
    }

    private func ageLabel(_ date: Date) -> String {
        let seconds = max(0, entry.date.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    private func taskSubtitle(_ task: AnkerCoreWidgetTask) -> String {
        if let due = task.due {
            return "\(task.area) · due \(due.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return task.area
    }
}

private extension AnkerCoreWidgetSnapshot {
    static var preview: Self {
        AnkerCoreWidgetSnapshot(
            updatedAt: Date(),
            recordings: [
                AnkerCoreWidgetRecording(id: 1, recordedAt: Date().addingTimeInterval(-240), stage: "Notion routing", state: "succeeded", title: "Processing complete", destination: nil),
                AnkerCoreWidgetRecording(id: 2, recordedAt: Date().addingTimeInterval(-900), stage: "Transcription", state: "running", title: "On-device transcription", destination: nil),
                AnkerCoreWidgetRecording(id: 3, recordedAt: Date().addingTimeInterval(-5_400), stage: "Audio fetch", state: "failed", title: "Connection interrupted", destination: nil),
            ],
            tasks: [
                AnkerCoreWidgetTask(id: "1", title: "Wire up application dashboards", due: Date().addingTimeInterval(86_400), priority: "High", area: "Work", url: URL(string: "https://www.notion.so")!),
                AnkerCoreWidgetTask(id: "2", title: "Review meeting follow-up", due: nil, priority: "Medium", area: "Work", url: URL(string: "https://www.notion.so")!),
                AnkerCoreWidgetTask(id: "3", title: "Create enclosure prototypes", due: nil, priority: "Medium", area: "Personal Work", url: URL(string: "https://www.notion.so")!),
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
