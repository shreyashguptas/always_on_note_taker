import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Record", systemImage: "waveform.circle.fill") {
                RecordView()
            }

            Tab("Notes", systemImage: "note.text") {
                NotesListView()
            }
        }
    }
}

#Preview {
    RootTabView()
}
