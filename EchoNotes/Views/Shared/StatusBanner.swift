import SwiftUI

/// Inline banner for pipeline conditions worth surfacing: mic permission
/// denied, speech model downloading, Apple Intelligence unavailable, etc.
struct StatusBanner: View {
    enum Kind {
        case info
        case warning
        case progress(Double?) // nil = indeterminate
    }

    let kind: Kind
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// Progress banners only: render a linear bar under the message instead
    /// of the circular spinner (used for longer-running work like
    /// transcription).
    var linearProgress = false

    var body: some View {
        HStack(spacing: 12) {
            leading
            if case .progress(let fraction) = kind, linearProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.footnote.weight(.medium))
                    if let fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(message)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var leading: some View {
        switch kind {
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .progress(let fraction):
            if linearProgress {
                // The linear bar under the message is the indicator; a
                // second spinner up front would be noise.
                Image(systemName: "text.bubble")
                    .foregroundStyle(Color.accentColor)
            } else if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var background: Color {
        switch kind {
        case .warning: Color.orange.opacity(0.12)
        case .info, .progress: Color.accentColor.opacity(0.10)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBanner(kind: .warning, message: "Microphone access is off. EchoNotes can't hear anything.", actionTitle: "Settings", action: {})
        StatusBanner(kind: .progress(0.4), message: "Downloading the on-device speech model…")
        StatusBanner(kind: .info, message: "Apple Intelligence is unavailable; using the basic summarizer.")
    }
    .padding()
}
