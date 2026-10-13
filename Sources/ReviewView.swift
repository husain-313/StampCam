//  ReviewView.swift
//  Review the current set before the PDF: delete, retake, add notes, or go back to add more.

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
              VStack(spacing: 0) {
                if !camera.shots.isEmpty { summary.padding([.horizontal, .top]) }
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
                        // Press and drag a photo onto another to change the order.
                        .draggable(shot.id.uuidString) {
                            cell(shot, number: index + 1)
                                .frame(width: 90)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let text = items.first, let id = UUID(uuidString: text) else { return false }
                            withAnimation(.easeInOut(duration: 0.2)) { camera.move(id, to: shot.id) }
                            return true
                        }
                    }
                }
                .padding()
              }
            }
            .safeAreaInset(edge: .bottom) {
                if !camera.shots.isEmpty {
                    VStack(spacing: 8) {
                        if camera.shots.count > 1 {
                            Text("Press and drag a photo to change the order. Tap one to add a note.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button { onCreatePDF() } label: {
                            Label("Create PDF", systemImage: "doc.richtext.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.yellow))
                        }
                        .disabled(camera.pendingCount > 0)
                        .opacity(camera.pendingCount > 0 ? 0.5 : 1)
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .background(.bar)
                }
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
            }
        }
    }

    /// Short summary of the set: how many photos, when and where.
    private var summary: some View {
        let places = Array(Set(camera.shots.compactMap(\.placeName).filter { !$0.isEmpty })).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            Label(StampText.dateRange(camera.shots.map(\.date)), systemImage: "calendar")
            if !places.isEmpty {
                Label(places.count == 1 ? places[0] : "\(places[0]) + \(places.count - 1) more",
                      systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
            }
            let notes = camera.shots.filter { $0.note != nil }.count
            if notes > 0 {
                Label(notes == 1 ? "1 note" : "\(notes) notes", systemImage: "text.bubble")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func cell(_ shot: Shot, number: Int) -> some View {
        Color.white.opacity(0.06)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                // Fit, so landscape photos are shown whole.
                if let thumbnail = camera.thumbnails[shot.id] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Location still being found for this photo.
                if shot.placeName == nil && !(shot.imported == true && shot.location == nil) && UserDefaults.standard.bool(forKey: Keys.showLocation) {
                    Image(systemName: "location.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if shot.note != nil {
                    Image(systemName: "text.bubble.fill")
                        .font(.caption2)
                        .foregroundStyle(.black)
                        .padding(5)
                        .background(Circle().fill(Color.yellow))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    @State private var editingNote = false
    @State private var noteDraft = ""

    private var index: Int? { camera.shots.firstIndex { $0.id == shotID } }

    private var shot: Shot? { index.map { camera.shots[$0] } }

    /// Re-render the preview when the area name arrives.
    private var previewKey: String {
        shot?.placeName ?? (shot == nil ? "none" : "pending")
    }

    private let noun = "Photo"

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let note = shot?.note {
                Button { startEditingNote() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.bubble.fill").foregroundStyle(.yellow)
                        Text(note)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.1)))
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(index.map { "\(noun) \($0 + 1) of \(camera.shots.count)" } ?? "")
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
                Button {
                    startEditingNote()
                } label: {
                    Label(shot?.note == nil ? "Add Note" : "Edit Note", systemImage: "text.bubble")
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
        .confirmationDialog("Delete this \(noun.lowercased())?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                camera.delete(shotID)
                dismiss()
            }
        }
        .alert("Note", isPresented: $editingNote) {
            TextField("Printed under the photo in the PDF", text: $noteDraft)
            Button("Save") { camera.setNote(shotID, noteDraft) }
            if shot?.note != nil {
                Button("Remove", role: .destructive) { camera.setNote(shotID, "") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short note, like what the photo shows. It's printed under the photo in the PDF.")
        }
        .task(id: previewKey) {
            // Shows the shot exactly as it will appear in the PDF.
            guard let shot else { return }
            let lines = camera.stampLines(for: shot)
            let style = StampStyle.current()
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                ShotRenderer.render(shot, lines: lines, style: style, maxDimension: 1600)
            }.value
        }
    }

    private func startEditingNote() {
        noteDraft = shot?.note ?? ""
        editingNote = true
    }
}
