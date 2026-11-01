import PressayAccount
import SwiftUI

/// The personal dictionary: applied after every engine, so names and jargon come out right.
struct DictionaryView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ProductivityModel.self) private var productivity
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false
    @State private var showsPro = false

    var body: some View {
        List {
            Section {
                if productivity.document.dictionary.isEmpty {
                    Text("dictionary.empty").foregroundStyle(.secondary)
                }
                ForEach(productivity.document.dictionary) { entry in
                    Button {
                        editing = entry
                    } label: {
                        DictionaryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("history.delete", systemImage: "trash", role: .destructive) {
                            productivity.delete(entry)
                        }
                    }
                }
            } footer: {
                if account.isPro {
                    #if PRESSAY_SYNC
                    Text("dictionary.footer.pro.sync")
                    #else
                    Text("dictionary.footer.pro")
                    #endif
                } else {
                    Text(String(
                        format: String(localized: "dictionary.footer.free"),
                        productivity.document.dictionary.count, ProLimits.freeDictionaryEntries
                    ))
                }
            }
            if !productivity.canAddWord(isPro: account.isPro) {
                Section {
                    Text("dictionary.limit").font(.callout)
                    Button("pro.discover") { showsPro = true }
                        .accessibilityIdentifier("dictionaryUpgrade")
                }
            }
        }
        .navigationTitle("dictionary.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("dictionary.add", systemImage: "plus") { isAdding = true }
                .disabled(!productivity.canAddWord(isPro: account.isPro))
                .accessibilityIdentifier("addWord")
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: DictionaryEntry(term: ""), isNew: true)
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry, isNew: false)
        }
        .navigationDestination(isPresented: $showsPro) { ProView() }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: entry.replacement?.isEmpty == false ? entry.replacement ?? entry.term : entry.term)
                .foregroundStyle(entry.enabled ? .primary : .secondary)
            if !entry.variants.isEmpty {
                Text(verbatim: entry.variants.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct DictionaryEditor: View {
    @Environment(ProductivityModel.self) private var productivity
    @Environment(\.dismiss) private var dismiss
    @State private var entry: DictionaryEntry
    @State private var heardAs: String
    let isNew: Bool

    init(entry: DictionaryEntry, isNew: Bool) {
        _entry = State(initialValue: entry)
        _heardAs = State(initialValue: entry.variants.joined(separator: ", "))
        self.isNew = isNew
    }

    private var edited: DictionaryEntry {
        var value = entry
        value.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        value.variants = heardAs.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("dictionary.term", text: $entry.term)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("wordTerm")
                } footer: {
                    Text("dictionary.term.footer")
                }
                Section {
                    TextField("dictionary.heardAs", text: $heardAs)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("wordHeardAs")
                } footer: {
                    Text("dictionary.heardAs.footer")
                }
                if !isNew {
                    Section {
                        Toggle("dictionary.enabled", isOn: $entry.enabled)
                    }
                }
            }
            .navigationTitle(isNew ? "dictionary.add" : "dictionary.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        productivity.save(edited)
                        dismiss()
                    }
                    .disabled(!edited.isValid)
                    .accessibilityIdentifier("saveWord")
                }
            }
        }
    }
}
