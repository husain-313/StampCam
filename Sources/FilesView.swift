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
    /// Saving copies of the selected PDFs to a folder in the Files app (they also stay here).
    @State private var exporting: ExportedPDFs?
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
                        Button { exporting = ExportedPDFs(urls: selectedURLs) } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel("Save to Files")
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
            // Copies go to the folder you pick in the Files app; the PDFs stay here too. (Before 4.3
            // they were moved, so they disappeared from Your PDFs without a word.)
            .sheet(item: $exporting, onDismiss: finishSelecting) { pdfs in
                FileExporter(urls: pdfs.urls) { exporting = nil }
                    .ignoresSafeArea()
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
        // Forget the text of PDFs deleted or renamed in the Files app.
        let urls = files.map(\.url)
        DispatchQueue.global(qos: .utility).async { PDFText.removeOrphans(keeping: urls) }
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

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

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
            // Time of the first photo and the date, like "5:17 PM · 19 Oct 2026".
            Text(verbatim: "\(PDFCard.time.string(from: file.takenAt)) · \(PDFCard.day.string(from: file.takenAt))")
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

/// PDFs to save to the Files app.
struct ExportedPDFs: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Saves copies of PDFs to a folder you pick in the Files app.
struct FileExporter: UIViewControllerRepresentable {
    let urls: [URL]
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Haptics.tap()
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
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
