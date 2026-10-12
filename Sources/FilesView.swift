//  FilesView.swift
//  Saved PDFs: open, share, delete.

import SwiftUI
import PDFKit

struct FilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [PDFFile] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(files) { file in
                    NavigationLink(value: file) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .font(.body.monospacedDigit())
                                .lineLimit(1)
                            Text("\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in
                    offsets.map { files[$0] }.forEach(FileStore.delete)
                    reload()
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
                PDFDetailView(file: file, onDelete: reload)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        files = FileStore.list()
    }
}

// MARK: - One PDF

struct PDFDetailView: View {
    let file: PDFFile
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        PDFKitView(url: file.url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: file.url)
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                }
            }
            .confirmationDialog("Delete this PDF?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete PDF", role: .destructive) {
                    FileStore.delete(file)
                    onDelete()
                    dismiss()
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
