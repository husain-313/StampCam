//  FilesView.swift
//  Saved PDFs as a grid of covers: open, rename (with smart suggestions), share, delete — one at a time or several together.

import SwiftUI
import PDFKit
import PhotosUI

struct FilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [PDFFile] = []
    @State private var path: [PDFFile] = []
    @State private var renaming: PDFFile?
    @State private var deleting: PDFFile?
    @State private var isSelecting = false
    @State private var selection = Set<URL>()
    @State private var confirmBulkDelete = false
    @State private var showDeleteAlert = false
    @State private var showMover = false
    /// Adds new photos to the end of this PDF by taking them with the camera.
    var onAddPhotos: (URL, AddPhotosSource) -> Void = { _, _ in }
    /// Photos picked from the library for this PDF (the library opens right here, on top).
    var onLibraryPicked: (URL, [Data]) -> Void = { _, _ in }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          spacing: 18) {
                    ForEach(files) { file in
                        PDFCard(file: file,
                                selecting: isSelecting,
                                selected: selection.contains(file.url))
                            .onTapGesture { tap(file) }
                            .contextMenu {
                                if !isSelecting {
                                    Button { addPhotos(file.url, .library) } label: {
                                        Label("Add from Library", systemImage: "photo.on.rectangle")
                                    }
                                    Button { onAddPhotos(file.url, .camera) } label: {
                                        Label("Take Photos", systemImage: "camera")
                                    }
                                    Button { renaming = file } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    ShareLink(item: file.url) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) { deleting = file } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView("No PDFs Yet",
                                           systemImage: "doc.richtext",
                                           description: Text("Your PDFs will show up here."))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PDFFile.self) { file in
                PDFDetailView(file: file,
                              onAddPhotos: { addPhotos(file.url, $0) },
                              onRename: { renaming = file },
                              onDelete: { delete(file) })
            }
            .navigationTitle(isSelecting ? (selection.isEmpty ? "Select PDFs" : "\(selection.count) Selected") : "Files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !files.isEmpty {
                        Button(isSelecting ? "Cancel" : "Select") {
                            withAnimation {
                                isSelecting.toggle()
                                selection.removeAll()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selection = allSelected ? [] : Set(files.map(\.url))
                        }
                        Spacer()
                        ShareLink(items: selectedURLs) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(selection.isEmpty)
                        Button { showMover = true } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel("Move to Files")
                        .disabled(selection.isEmpty)
                        Button(role: .destructive) { confirmBulkDelete = true } label: {
                            Image(systemName: "trash")
                        }
                        .tint(.red)
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .confirmationDialog(selection.count == 1 ? "Delete 1 PDF?" : "Delete \(selection.count) PDFs?",
                                isPresented: $confirmBulkDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    files.filter { selection.contains($0.url) }.forEach(FileStore.delete)
                    finishSelecting()
                }
            }
            .fileMover(isPresented: $showMover, files: selectedURLs) { result in
                // Moved to the folder you picked in the Files app: forget their read text.
                if case .success = result { selectedURLs.forEach(PDFText.delete) }
                finishSelecting()
            }
            .onAppear(perform: reload)

            .sheet(item: $renaming) { file in
                RenameSheet(url: file.url) { _ in
                    renaming = nil
                    path.removeAll()      // back to the list with the new name
                    reload()
                }
            }
            // Swipe or long-press delete from the list.
            .alert("Delete this PDF?", isPresented: $showDeleteAlert, presenting: deleting) { file in
                Button("Delete", role: .destructive) { delete(file) }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { file in
                Text("\"\(file.name)\" will be deleted. This can't be undone.")
            }
            .onChange(of: deleting) { _, file in
                if file != nil { showDeleteAlert = true }
            }
            .onChange(of: showDeleteAlert) { _, shown in
                if !shown { deleting = nil }
            }
        }
    }

    private var allSelected: Bool { !files.isEmpty && selection.count == files.count }
    private var selectedURLs: [URL] { files.map(\.url).filter { selection.contains($0) } }

    private func finishSelecting() {
        selection.removeAll()
        isSelecting = false
        reload()
    }

    private func addPhotos(_ url: URL, _ source: AddPhotosSource) {
        if source == .library {
            // Opens right away on top of Your PDFs (waiting a moment if a menu is still closing).
            LibraryPicker.present { photos in onLibraryPicked(url, photos) }
        } else {
            onAddPhotos(url, source)
        }
    }

    /// Tap a card: open it, or (while selecting) tick it.
    private func tap(_ file: PDFFile) {
        if isSelecting {
            if selection.contains(file.url) { selection.remove(file.url) } else { selection.insert(file.url) }
            Haptics.tick()
        } else {
            path.append(file)
        }
    }

    private func delete(_ file: PDFFile) {
        FileStore.delete(file)
        deleting = nil
        path.removeAll()
        reload()
        Haptics.tap()
    }

    private func reload() {
        files = FileStore.list()
        selection = selection.filter { url in files.contains { $0.url == url } }
    }
}

// MARK: - Card in the grid

/// A PDF shown like a photo album: its first photo as the cover, the name and date under it.
struct PDFCard: View {
    let file: PDFFile
    var selecting = false
    var selected = false
    @State private var cover: UIImage?
    @State private var pages = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color.white.opacity(0.06)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let cover {
                            Image(uiImage: cover)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "doc.richtext")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.yellow : Color.white.opacity(0.15), lineWidth: selected ? 3 : 0.6))

                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .shadow(radius: 2)
                        .padding(8)
                } else if pages > 1 {
                    Label("\(pages)", systemImage: "doc.on.doc.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(7)
                }
            }

            Text(file.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(file.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: file) { await load() }
    }

    private func load() async {
        let url = file.url
        let result = await Task.detached(priority: .utility) { () -> (UIImage?, Int) in
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return (nil, 0) }
            let image = page.thumbnail(of: CGSize(width: 480, height: 480), for: .mediaBox)
            return (image, document.pageCount)
        }.value
        cover = result.0
        pages = result.1
    }
}

/// Where new photos for an existing PDF come from.
enum AddPhotosSource { case camera, library }

// MARK: - One PDF

struct PDFDetailView: View {
    let file: PDFFile
    var onAddPhotos: (AddPhotosSource) -> Void
    var onRename: () -> Void
    /// Called after you confirm; deletes the file and goes back to the list.
    var onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var arranging = false
    /// Changes after the pages are rearranged, so the PDF is shown again.
    @State private var version = 0

    var body: some View {
        PDFKitView(url: file.url)
            .id(version)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { onAddPhotos(.library) } label: {
                            Label("Add from Library", systemImage: "photo.on.rectangle")
                        }
                        Button { onAddPhotos(.camera) } label: {
                            Label("Take Photos", systemImage: "camera")
                        }
                    } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                    .accessibilityLabel("Add Photos")
                    Button { arranging = true } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Arrange Pages")
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                    }
                    ShareLink(item: file.url)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                }
            }
            .sheet(isPresented: $arranging) {
                ArrangePagesView(url: file.url) { changed in
                    arranging = false
                    if changed { version += 1 }
                }
            }
            // The question is asked here, on the PDF itself, so the answer always reaches it.
            .alert("Delete this PDF?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(file.name)\" will be deleted. This can't be undone.")
            }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
