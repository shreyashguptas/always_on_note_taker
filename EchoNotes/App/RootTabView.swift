import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Record", systemImage: "waveform.circle.fill") {
                Text("Record")
            }

            Tab("Notes", systemImage: "note.text") {
                Text("Notes")
            }
        }
    }
}

#Preview {
    RootTabView()
}
