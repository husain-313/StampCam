//  FilesView.swift
//  Saved PDFs: open, rename (with smart suggestions), share, delete — one at a time or several together.

import SwiftUI
import PDFKit

struct FilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [PDFFile] = []
    @State private var path: [PDFFile] = []
    @State private var renaming: PDFFile?
    @State private var deleting: PDFFile?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<URL>()
    @State private var confirmBulkDelete = false
    @State private var showDeleteAlert = false
    @State private var showMover = false
    /// Adds new photos to the end of this PDF: take them with the camera, or pick them from the library.
    var onAddPhotos: (URL, AddPhotosSource) -> Void = { _, _ in }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                ForEach(files) { file in
                    NavigationLink(value: file) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .lineLimit(1)
                            Text("\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleting = file
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            renaming = file
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button { onAddPhotos(file.url, .camera) } label: {
                            Label("Take Photos", systemImage: "camera")
                        }
                        Button { onAddPhotos(file.url, .library) } label: {
                            Label("Add from Library", systemImage: "photo.on.rectangle")
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
            .environment(\.editMode, $editMode)
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
                              onAddPhotos: { onAddPhotos(file.url, $0) },
                              onRename: { renaming = file },
                              onDelete: { delete(file) })
            }
            .navigationTitle(isSelecting ? (selection.isEmpty ? "Select PDFs" : "\(selection.count) Selected") : "Files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !files.isEmpty {
                        Button(isSelecting ? "Cancel" : "Select") {
                            withAnimation {
                                editMode = isSelecting ? .inactive : .active
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
            .fileMover(isPresented: $showMover, files: selectedURLs) { _ in
                // Moved to the folder you picked in the Files app.
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

    private var isSelecting: Bool { editMode.isEditing }
    private var allSelected: Bool { !files.isEmpty && selection.count == files.count }
    private var selectedURLs: [URL] { files.map(\.url).filter { selection.contains($0) } }

    private func finishSelecting() {
        selection.removeAll()
        editMode = .inactive
        reload()
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

    var body: some View {
        PDFKitView(url: file.url)
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
