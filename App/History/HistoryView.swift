import PressayAccount
import PressayCore
import SwiftUI
import UIKit

/// Past dictations, kept encrypted on this iPhone only: copy, delete one or all. With Pro, the
/// whole history and its search; without it, the last days, the rest staying sealed until Pro.
struct HistoryView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(AccountModel.self) private var account
    @State private var query = ""
    @State private var confirmsClear = false

    private var visible: [HistoryEntry] {
        dictation.history.visibleEntries(isPro: account.isPro, freeDays: ProLimits.freeHistoryDays)
    }

    var body: some View {
        NavigationStack {
            let visible = visible
            let results = account.isPro ? visible.matching(query) : visible
            List {
                if !account.isPro, !dictation.history.isEmpty {
                    Section {
                        NavigationLink {
                            ProView()
                        } label: {
                            let hidden = dictation.history.count - visible.count
                            Group {
                                if hidden > 0 {
                                    Text(String(format: String(localized: "history.limit.hidden"), ProLimits.freeHistoryDays, hidden))
                                } else {
                                    Text(String(format: String(localized: "history.limit"), ProLimits.freeHistoryDays))
                                }
                            }
                            .font(.footnote)
                        }
                        .accessibilityIdentifier("historyUpgrade")
                    }
                }
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
                            if let original = entry.originalText {
                                Button("history.copyOriginal", systemImage: "text.quote") {
                                    UIPasteboard.general.string = original
                                }
                            }
                            Button("history.delete", systemImage: "trash", role: .destructive) {
                                dictation.removeFromHistory(entry)
                            }
                        }
                }
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label("history.empty", systemImage: "clock")
                    } description: {
                        Text("history.privacy")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .modifier(HistorySearchField(isEnabled: account.isPro, query: $query))
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

/// Search comes with Pro: without it the field is left out rather than shown disabled.
private struct HistorySearchField: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $query, prompt: Text("history.search"))
        } else {
            content
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
