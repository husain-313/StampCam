//  RenameSheet.swift
//  Rename a PDF: smart suggestions, or tap any text in the photos to use it as the name.

import SwiftUI

struct RenameSheet: View {
    let url: URL
    /// Called with the final URL (new name, or the same URL if skipped).
    var onFinish: (URL) -> Void

    @State private var name: String
    @State private var suggestions: [String] = []
    @State private var pages: [TextScanner.Page] = []
    @State private var scanning = true
    @State private var failed = false
    @FocusState private var fieldFocused: Bool

    /// Pages read for the suggestions (the first photos), and at most this many shown to tap.
    private let suggestionPages = 3
    private let maxPages = 12

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
                    if pages.isEmpty {
                        HStack(spacing: 12) {
                            if scanning {
                                ProgressView()
                                Text("Reading text in your photos…")
                            } else {
                                Text("No text found in the photos.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(pages) { page in
                                    pageView(page)
                                }
                                if scanning {
                                    ProgressView().frame(width: 60, height: 300)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                } header: {
                    Label("Tap Text in Your Photos", systemImage: "hand.tap")
                } footer: {
                    Text("Tap any highlighted text to use it as the name. Swipe to see more photos.")
                }

                Section {
                    if suggestions.isEmpty {
                        Text(scanning ? "Looking for names…" : "No suggestions.")
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
                    Text("Your note, and text read from your photos like a shop sign. Everything stays on your iPhone.")
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
            .task { await readPages() }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Photos with tappable text

    private func pageView(_ page: TextScanner.Page) -> some View {
        Image(uiImage: page.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ForEach(page.lines) { line in
                        textBox(line, in: geo.size)
                    }
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// A yellow box over one line of text; tap it to use that text as the name.
    private func textBox(_ line: TextScanner.Line, in size: CGSize) -> some View {
        let rect = CGRect(x: line.box.minX * size.width,
                          y: line.box.minY * size.height,
                          width: line.box.width * size.width,
                          height: line.box.height * size.height)
        let selected = cleanName == FileStore.sanitize(line.text)
        return Button {
            pick(line.text)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.yellow.opacity(selected ? 0.5 : 0.2))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.yellow, lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: max(rect.width + 6, 22), height: max(rect.height + 6, 22))
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel(line.text)
    }

    private func pick(_ text: String) {
        name = text
        fieldFocused = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Reading

    private func readPages() async {
        let count = min(TextScanner.pageCount(url), maxPages)
        var found: [TextScanner.Found] = []
        var read = 0
        for index in 0..<count {
            guard let page = await TextScanner.readPage(url, index: index) else { continue }
            if !page.lines.isEmpty {
                withAnimation(.easeOut(duration: 0.2)) { pages.append(page) }
            }
            if read < suggestionPages {
                found += page.found
                read += 1
                if read == suggestionPages { updateSuggestions(found) }
            }
        }
        if read < suggestionPages { updateSuggestions(found) }
        scanning = false
    }

    private func updateSuggestions(_ found: [TextScanner.Found]) {
        var list = TextScanner.suggestions(from: found)
        // The note from Settings is usually the best name, so it comes first.
        let note = StampText.note
        if !note.isEmpty {
            let key = TextScanner.normalize(note)
            list.removeAll { TextScanner.normalize($0) == key }
            list.insert(note, at: 0)
        }
        suggestions = list
    }

    private func save() {
        guard let newURL = FileStore.rename(url, to: name) else {
            failed = true
            return
        }
        onFinish(newURL)
    }
}
