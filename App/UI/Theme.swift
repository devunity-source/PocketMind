import SwiftUI
import PocketMindCore

/// Design tokens. Every screen takes colours, spacing and radii from here.
enum Theme {
    enum Palette {
        static let background = Color(red: 0.043, green: 0.043, blue: 0.063)
        static let surface = Color(red: 0.086, green: 0.086, blue: 0.118)
        static let surfaceRaised = Color(red: 0.125, green: 0.125, blue: 0.165)
        static let stroke = Color.white.opacity(0.07)
        static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)
        static let accentSoft = Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.18)
        static let textPrimary = Color.white
        static let textSecondary = Color(red: 0.62, green: 0.62, blue: 0.69)
        static let danger = Color(red: 0.957, green: 0.247, blue: 0.369)
        static let success = Color(red: 0.29, green: 0.80, blue: 0.56)
        static let warning = Color(red: 0.98, green: 0.72, blue: 0.27)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 16
        static let large: CGFloat = 22
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.Palette.stroke))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Chip: View {
    let text: String
    var selected = false

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Theme.Palette.textPrimary)
            .background(selected ? Theme.Palette.accent : Theme.Palette.surfaceRaised, in: Capsule())
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(destructive ? Theme.Palette.danger : Theme.Palette.accent,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Bars of recent microphone levels, newest on the right.
struct WaveformView: View {
    let levels: [Float]
    var active = true

    var body: some View {
        Canvas { context, size in
            let count = AudioRecorderService.levelCount
            let step = size.width / CGFloat(count)
            let barWidth = max(1.5, step * 0.55)
            let offset = count - levels.count
            for (index, level) in levels.enumerated() {
                let height = max(3, CGFloat(level) * size.height)
                let x = CGFloat(index + offset) * step + (step - barWidth) / 2
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                let age = Double(index + offset) / Double(count)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(Theme.Palette.accent.opacity(active ? 0.35 + 0.65 * age : 0.3)))
            }
        }
        .accessibilityLabel("Audio level")
        .accessibilityValue(active ? "Recording" : "Paused")
    }
}

struct StatusBadge: View {
    let recording: Recording
    let job: ProcessingPipeline.Job?

    var body: some View {
        if let job {
            switch job.stage {
            case .queued: label("Waiting", "clock", Theme.Palette.textSecondary)
            case .transcribing: label("Transcribing \(Int(job.progress * 100))%", "waveform", Theme.Palette.accent)
            case .summarizing: label("Summarizing", "sparkles", Theme.Palette.accent)
            }
        } else {
            switch recording.status {
            case .recorded: label("Not transcribed", "waveform.slash", Theme.Palette.textSecondary)
            case .transcribing, .transcribed: label("Transcribed", "text.alignleft", Theme.Palette.textSecondary)
            case .summarizing, .ready: label("Summary ready", "checkmark.circle", Theme.Palette.success)
            case .failed: label("Failed", "exclamationmark.triangle", Theme.Palette.danger)
            }
        }
    }

    private func label(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let job: ProcessingPipeline.Job?
    var preview: String?

    private var icon: String {
        switch recording.kind {
        case .meeting: "person.2.fill"
        case .call: "phone.fill"
        case .note: "note.text"
        case .imported: "square.and.arrow.down"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Theme.Palette.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(recording.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if recording.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.Palette.warning)
                            .accessibilityLabel("Favorite")
                    }
                    Spacer(minLength: 4)
                    Text(Format.day(recording.createdAt))
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(Format.shortDuration(recording.duration))
                    Text("•")
                    StatusBadge(recording: recording, job: job)
                }
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)

                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Presents the system share sheet for a file and removes the file afterwards.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            // Exports are plaintext; do not leave them behind once shared or cancelled.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Navigation target for a recording, optionally at a position in the audio.
struct RecordingRoute: Hashable {
    let recordingID: String
    var seekTo: Double?
}

extension View {
    func screenBackground() -> some View {
        self.background(Theme.Palette.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}
