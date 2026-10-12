//  RenameSheet.swift
//  Rename a PDF, with smart suggestions read from the text in its photos.

import SwiftUI

struct RenameSheet: View {
    let url: URL
    /// Called with the final URL (new name, or the same URL if skipped).
    var onFinish: (URL) -> Void

    @State private var name: String
    @State private var suggestions: [String] = []
    @State private var scanning = true
    @State private var failed = false
    @FocusState private var fieldFocused: Bool

    init(url: URL, onFinish: @escaping (URL) -> Void) {
        self.url = url
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
                    if scanning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reading text in your photos…")
                                .foregroundStyle(.secondary)
                        }
                    } else if suggestions.isEmpty {
                        Text("No text found in the photos.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                name = suggestion
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
                    }
                } header: {
                    Label("Smart Suggestions", systemImage: "sparkles")
                } footer: {
                    Text("Read from the text in your photos, like a shop sign. Everything stays on your iPhone.")
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
            .task {
                suggestions = await TextScanner.suggestions(for: url)
                scanning = false
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        guard let newURL = FileStore.rename(url, to: name) else {
            failed = true
            return
        }
        onFinish(newURL)
    }
}
