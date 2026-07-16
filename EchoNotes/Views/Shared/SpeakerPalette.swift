import SwiftUI

/// Stable colors for speaker dots in transcripts and the People screen. Indexed
/// by `Speaker.colorIndex` (wraps past eight speakers) or, for voices not
/// yet identified, by their order of appearance in a session.
enum SpeakerPalette {
    private static let colors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown,
    ]

    static func color(for index: Int) -> Color {
        colors[abs(index) % colors.count]
    }

    /// Neutral dot for diarized-but-unidentified voices.
    static let unidentified = Color.gray

    /// Display name for a segment's language badge ("Hindi" for "hi"),
    /// falling back to the raw code.
    static func languageName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}
