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
    @State private var showMover = false
    /// Adds new photos to the end of this PDF (back to the camera).
    var onAddPhotos: (URL) -> Void = { _ in }

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
                        Button { onAddPhotos(file.url) } label: {
                            Label("Add Photos", systemImage: "plus.rectangle.on.rectangle")
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
                              onAddPhotos: { onAddPhotos(file.url) },
                              onRename: { renaming = file },
                              onDelete: { deleting = file })
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
            .confirmationDialog("Delete this PDF?",
                                isPresented: Binding(get: { deleting != nil },
                                                     set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible,
                                presenting: deleting) { file in
                Button("Delete PDF", role: .destructive) {
                    FileStore.delete(file)
                    deleting = nil
                    path.removeAll()
                    reload()
                }
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

    private func reload() {
        files = FileStore.list()
        selection = selection.filter { url in files.contains { $0.url == url } }
    }
}

// MARK: - One PDF

struct PDFDetailView: View {
    let file: PDFFile
    var onAddPhotos: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        PDFKitView(url: file.url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: onAddPhotos) {
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                    .accessibilityLabel("Add Photos")
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                    }
                    ShareLink(item: file.url)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                }
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
