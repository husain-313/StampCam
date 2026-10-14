//  RenameSheet.swift
//  Rename a PDF: pick one of the smart suggestions, or type a name.

import SwiftUI

struct RenameSheet: View {
    let url: URL
    /// An extra name to offer, like "Jidhafs – 14 Oct" (area and date of the photos).
    var extraSuggestion: String? = nil
    /// Called with the final URL (new name, or the same URL if skipped).
    var onFinish: (URL) -> Void

    @State private var name: String
    @State private var suggestions: [String] = []
    @State private var scanning = true
    @State private var failed = false
    @FocusState private var fieldFocused: Bool

    private let maxSuggestions = 8

    init(url: URL, extraSuggestion: String? = nil, onFinish: @escaping (URL) -> Void) {
        self.url = url
        self.extraSuggestion = extraSuggestion
        self.onFinish = onFinish
        _name = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    private var cleanName: String { FileStore.sanitize(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section("File Name") {
                    HStack {
                        TextField("Name", text: $name)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit(save)
                        if !name.isEmpty {
                            Button {
                                name = ""
                                fieldFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if failed {
                        Text("Couldn't rename the file. Try another name.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            pick(suggestion)
                        } label: {
                            HStack {
                                Text(suggestion)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer()
                                if cleanName == FileStore.sanitize(suggestion) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                    if scanning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reading your photos…")
                        }
                        .foregroundStyle(.secondary)
                    } else if suggestions.isEmpty {
                        Text("No suggestions.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Smart Suggestions", systemImage: "sparkles")
                } footer: {
                    Text("Your note, the place and date, and names read from your photos. Everything stays on your iPhone.")
                }
            }
            .navigationTitle("Name PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { onFinish(url) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .bold()
                        .disabled(cleanName.isEmpty)
                }
            }
            .task { await load() }
        }
        .interactiveDismissDisabled()
    }

    private func pick(_ text: String) {
        name = text
        fieldFocused = false
        Haptics.tick()
    }

    // MARK: Suggestions

    private func load() async {
        // Quick ones first, so the list is never empty while the photos are read.
        suggestions = merge(read: [])
        let read = await TextScanner.suggestions(for: url)
        withAnimation(.easeOut(duration: 0.2)) {
            suggestions = merge(read: read)
            scanning = false
        }
    }

    /// Note first, then names read from the photos, then area and date. No repeats.
    private func merge(read: [String]) -> [String] {
        var list: [String] = []
        var seen = Set<String>()
        func add(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            let key = TextScanner.normalize(text)
            guard !key.isEmpty, !seen.contains(key), list.count < maxSuggestions else { return }
            seen.insert(key)
            list.append(text)
        }
        add(StampText.note)
        // Keep a spot for the area and date at the end.
        let readLimit = maxSuggestions - (extraSuggestion == nil ? 0 : 1)
        for text in read where list.count < readLimit { add(text) }
        add(extraSuggestion)
        return list
    }

    private func save() {
        guard let newURL = FileStore.rename(url, to: name) else {
            failed = true
            return
        }
        onFinish(newURL)
    }
}
