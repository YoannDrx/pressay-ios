import PressayCore
import SwiftUI
import UIKit

/// Past dictations, kept encrypted on this iPhone only: search, copy, delete one or all.
struct HistoryView: View {
    @Environment(DictationController.self) private var dictation
    @State private var query = ""
    @State private var confirmsClear = false

    var body: some View {
        NavigationStack {
            let results = dictation.history.matching(query)
            List {
                ForEach(results) { entry in
                    HistoryRow(entry: entry)
                        .swipeActions {
                            Button("history.delete", systemImage: "trash", role: .destructive) {
                                dictation.removeFromHistory(entry)
                            }
                        }
                        .contextMenu {
                            Button("home.copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = entry.text
                            }
                            Button("history.delete", systemImage: "trash", role: .destructive) {
                                dictation.removeFromHistory(entry)
                            }
                        }
                }
            }
            .overlay {
                if dictation.history.isEmpty {
                    ContentUnavailableView {
                        Label("history.empty", systemImage: "clock")
                    } description: {
                        Text("history.privacy")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: Text("history.search"))
            .navigationTitle("history.title")
            .toolbar {
                if !dictation.history.isEmpty {
                    Button("history.clear", systemImage: "trash", role: .destructive) { confirmsClear = true }
                        .accessibilityIdentifier("clearHistory")
                }
            }
            .confirmationDialog("history.clear.confirm", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("history.clear", role: .destructive) { dictation.clearHistory() }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .lineLimit(6)
            HStack(spacing: 6) {
                Text(entry.createdAt, style: .date)
                EntryDetails(entry: entry)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
