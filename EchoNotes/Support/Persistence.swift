import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([
        RecordingSession.self,
        TranscriptSegment.self,
        GeneratedNote.self,
        Speaker.self,
        SpeakerReviewItem.self,
    ])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    /// Directory that holds one .m4a per session, under Application Support.
    /// Created once per launch, not on every access.
    static let recordingsDirectory: URL = {
        let base = URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func audioURL(forFileName fileName: String) -> URL {
        recordingsDirectory.appending(path: fileName)
    }

    static func deleteAudioFile(named fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: audioURL(forFileName: fileName))
    }
}
