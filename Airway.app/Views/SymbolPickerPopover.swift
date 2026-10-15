import SwiftUI

struct SymbolPickerPopover: View {
    @Binding var selectedSymbol: String
    @Environment(\.dismiss) var dismiss
    
    // Filtered to what the running macOS can draw: several of these arrived
    // after macOS 13 and would otherwise be blank, unpickable tiles.
    let symbols = AirwaySymbol.renderable([
        "fan.fill", "fan.slash", "fan.slash.fill", "fan.desk", "fan.desk.fill",
        "fan.ceiling", "fan.ceiling.fill", "fan.floor", "fan.floor.fill",
        "fan.oscillation", "fan.oscillation.fill",
        "wind", "wind.snow", "snowflake", "thermometer.sun", "thermometer.snowflake",
        "laptopcomputer", "desktopcomputer", "macpro.gen1", "macpro.gen2", "macpro.gen3",
        "macmini", "macstudio", "headphones", "speaker.wave.3", "speaker.wave.3.fill",
        "music.note", "music.note.list", "gamecontroller.fill", "cpu"
    ])
    
    let columns = [GridItem(.adaptive(minimum: 36))]
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(symbols, id: \.self) { sym in
                        Button {
                            selectedSymbol = sym
                            dismiss()
                        } label: {
                            Image(systemName: sym)
                                .font(.title2)
                                .frame(width: 36, height: 36)
                                .background(selectedSymbol == sym ? Color.accentColor : Color.clear)
                                .foregroundColor(selectedSymbol == sym ? .white : .primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .frame(width: 280, height: 300)
            
            Divider()
            
            HStack {
                Button("Clear") {
                    selectedSymbol = ""
                    dismiss()
                }
                Spacer()
                Button {
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Label("Emoji", systemImage: "face.smiling")
                }
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
