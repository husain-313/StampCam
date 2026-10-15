//  ArrangePagesView.swift
//  Change the order of the photos in a saved PDF (drag, or "Move to First"), or remove one.

import SwiftUI
import PDFKit

struct ArrangePagesView: View {
    let url: URL
    /// Called when closing; true if the PDF was changed.
    var onFinish: (Bool) -> Void

    private struct PageItem: Identifiable, Equatable {
        let id: Int            // the page's place in the saved PDF
        let image: UIImage?
        static func == (a: PageItem, b: PageItem) -> Bool { a.id == b.id }
    }

    @State private var items: [PageItem] = []
    @State private var original: [Int] = []
    @State private var loading = true
    @State private var failed = false

    private var changed: Bool { items.map(\.id) != original }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, number: index + 1)
                            .contextMenu {
                                if index > 0 {
                                    Button { move(index, to: 0) } label: {
                                        Label("Move to First", systemImage: "arrow.up.to.line")
                                    }
                                }
                                if index < items.count - 1 {
                                    Button { move(index, to: items.count - 1) } label: {
                                        Label("Move to Last", systemImage: "arrow.down.to.line")
                                    }
                                }
                                if items.count > 1 {
                                    Button(role: .destructive) { remove(index) } label: {
                                        Label("Remove Page", systemImage: "trash")
                                    }
                                }
                            }
                    }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                        Haptics.tick()
                    }
                    .onDelete { offsets in
                        guard items.count - offsets.count >= 1 else { return }
                        items.remove(atOffsets: offsets)
                    }
                } footer: {
                    Text("Drag ≡ to change the order. Press and hold a page for Move to First, or swipe left to remove it.")
                }
                if failed {
                    Text("Couldn't save the changes.")
                        .foregroundStyle(.red)
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Arrange Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .bold()
                        .disabled(!changed)
                }
            }
            .task { await load() }
        }
        .interactiveDismissDisabled(changed)
    }

    private func row(_ item: PageItem, number: Int) -> some View {
        HStack(spacing: 14) {
            Group {
                if let image = item.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 84, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Page \(number)")
                .font(.headline)
            if number == 1 {
                Text("Cover")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
            }
        }
        .padding(.vertical, 2)
    }

    private func move(_ index: Int, to target: Int) {
        withAnimation {
            let item = items.remove(at: index)
            items.insert(item, at: target)
        }
        Haptics.tick()
    }

    private func remove(_ index: Int) {
        _ = withAnimation { items.remove(at: index) }
    }

    private func load() async {
        let url = url
        let pages = await Task.detached(priority: .userInitiated) { () -> [PageItem] in
            guard let document = PDFDocument(url: url) else { return [] }
            return (0..<document.pageCount).map { i in
                PageItem(id: i, image: document.page(at: i)?.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox))
            }
        }.value
        items = pages
        original = pages.map(\.id)
        loading = false
    }

    private func save() {
        guard FileStore.arrangePages(url, order: items.map(\.id)) else {
            failed = true
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onFinish(true)
    }
}
