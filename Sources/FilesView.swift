//  FilesView.swift
//  Saved PDFs: open, rename (with smart suggestions), share, delete.

import SwiftUI
import PDFKit

struct FilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [PDFFile] = []
    @State private var path: [PDFFile] = []
    @State private var renaming: PDFFile?
    @State private var deleting: PDFFile?

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView("No PDFs Yet",
                                           systemImage: "doc.richtext",
                                           description: Text("Your PDFs will show up here."))
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PDFFile.self) { file in
                PDFDetailView(file: file,
                              onRename: { renaming = file },
                              onDelete: { deleting = file })
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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

    private func reload() {
        files = FileStore.list()
    }
}

// MARK: - One PDF

struct PDFDetailView: View {
    let file: PDFFile
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        PDFKitView(url: file.url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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
