import PressayCore
import SwiftUI

/// Past dictations, kept on this iPhone only.
struct HistoryView: View {
    @Environment(DictationController.self) private var dictation
    @State private var confirmsClear = false

    var body: some View {
        List {
            if dictation.history.isEmpty {
                Text("history.empty")
                    .foregroundStyle(.secondary)
            }
            ForEach(dictation.history) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.text)
                        .textSelection(.enabled)
                    HStack {
                        Text(entry.createdAt, style: .date)
                        EntryDetails(entry: entry)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                offsets.map { dictation.history[$0] }.forEach(dictation.removeFromHistory)
            }
        }
        .navigationTitle("history.title")
        .toolbar {
            if !dictation.history.isEmpty {
                Button("history.clear", role: .destructive) { confirmsClear = true }
            }
        }
        .confirmationDialog("history.clear.confirm", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("history.clear", role: .destructive) { dictation.clearHistory() }
        }
    }
}
