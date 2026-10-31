import PressayCore
import PressayShared
import SwiftUI

/// The support journal: events, timings, counts and short tags from the app, the keyboard
/// and the widgets. Never dictated or typed text (`LogValue` has no case for it), so it can
/// be shared with support as is.
struct JournalView: View {
    @State private var lines: [JournalLine] = []
    @State private var exportURL: URL?
    @State private var confirmsClear = false

    var body: some View {
        List {
            Section {
                Text("journal.explanation")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: line.event)
                                .font(.callout.monospaced().weight(.semibold))
                            Spacer()
                            Text(verbatim: line.process)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: line.timestamp)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if !line.details.isEmpty {
                            Text(verbatim: line.details)
                                .font(.caption.monospaced())
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .overlay {
            if lines.isEmpty {
                ContentUnavailableView("journal.empty", systemImage: "doc.text")
            }
        }
        .navigationTitle("journal.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("journal.share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareJournal")
            }
            Menu {
                Button("journal.clear", systemImage: "trash", role: .destructive) { confirmsClear = true }
            } label: {
                Label("journal.more", systemImage: "ellipsis")
            }
        }
        .confirmationDialog("journal.clear.confirm", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("journal.clear", role: .destructive) {
                PressayLog.shared.clear()
                load()
            }
        }
        .refreshable { load() }
        .onAppear(perform: load)
    }

    private func load() {
        let journal = PressayLog.shared.readAll()
        lines = JournalLine.parse(journal)
        exportURL = Self.export(journal)
    }

    /// A copy in the temporary folder, so the share sheet sends a file named after Pressay.
    private static func export(_ journal: String) -> URL? {
        guard !journal.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pressay-journal.jsonl")
        do {
            try Data(journal.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
