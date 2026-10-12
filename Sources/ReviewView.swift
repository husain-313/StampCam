//  ReviewView.swift
//  Review the current set before the PDF: delete, retake, or go back to add more.

import SwiftUI

struct ReviewView: View {
    @ObservedObject var camera: CameraModel
    var onRetake: (UUID) -> Void
    var onCreatePDF: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(camera.shots.enumerated()), id: \.element.id) { index, shot in
                        NavigationLink(value: shot.id) {
                            cell(shot, number: index + 1)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                onRetake(shot.id)
                            } label: {
                                Label("Retake", systemImage: "arrow.triangle.2.circlepath.camera")
                            }
                            Button(role: .destructive) {
                                camera.delete(shot.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
            .overlay {
                if camera.shots.isEmpty && camera.pendingCount == 0 {
                    ContentUnavailableView("No Photos",
                                           systemImage: "photo.on.rectangle",
                                           description: Text("Tap Add Photos to keep shooting."))
                }
            }
            .navigationTitle(camera.shots.count == 1 ? "1 Photo" : "\(camera.shots.count) Photos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                ShotDetailView(camera: camera, shotID: id, onRetake: { onRetake(id) })
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Add Photos", systemImage: "camera")
                            .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create PDF") { onCreatePDF() }
                        .bold()
                        .disabled(camera.shots.isEmpty || camera.pendingCount > 0)
                }
            }
        }
    }

    private func cell(_ shot: Shot, number: Int) -> some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                Image(uiImage: shot.thumbnail)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                Text("\(number)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .padding(6)
            }
            .overlay {
                if camera.replacingIDs.contains(shot.id) {
                    ZStack {
                        Color.black.opacity(0.5)
                        ProgressView().tint(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
    }
}

// MARK: - One photo, full size

struct ShotDetailView: View {
    @ObservedObject var camera: CameraModel
    let shotID: UUID
    var onRetake: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var confirmDelete = false

    private var index: Int? { camera.shots.firstIndex { $0.id == shotID } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if index == nil {
                ContentUnavailableView("Photo Removed", systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(index.map { "Photo \($0 + 1) of \(camera.shots.count)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    onRetake()
                } label: {
                    Label("Retake", systemImage: "arrow.triangle.2.circlepath.camera")
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .tint(.red)
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) {
                camera.delete(shotID)
                dismiss()
            }
        }
        .task {
            guard let i = index else { return }
            let data = camera.shots[i].data
            image = await Task.detached { UIImage(data: data) }.value
        }
    }
}
