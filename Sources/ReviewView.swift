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
            .safeAreaInset(edge: .bottom) {
                if camera.shots.count > 1 {
                    Text("Press and drag a photo to change the order.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create PDF") { onCreatePDF() }
                        .bold()
                        .disabled(camera.shots.isEmpty || camera.pendingCount > 0)
                }
            }
        }
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
                if shot.placeName == nil && shot.shotKind == .photo && !(shot.imported == true && shot.location == nil) && UserDefaults.standard.bool(forKey: Keys.showLocation) {
                    Image(systemName: "location.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(6)
                }
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

    private var shot: Shot? { index.map { camera.shots[$0] } }

    /// Re-render the preview when the area name or the shot's options change.
    private var previewKey: String {
        guard let shot else { return "none" }
        return [shot.placeName ?? "pending",
                shot.filter?.rawValue ?? "",
                shot.idBackground?.rawValue ?? "",
                shot.idSize?.rawValue ?? ""].joined(separator: "|")
    }

    private var noun: String {
        switch shot?.shotKind {
        case .document: return "Page"
        case .idPhoto: return "ID Photo"
        default: return "Photo"
        }
    }

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

            if let shot {
                options(for: shot)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(index.map { "\(noun) \($0 + 1) of \(camera.shots.count)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if shot?.shotKind != .document {
                    Button {
                        onRetake()
                    } label: {
                        Label("Retake", systemImage: "arrow.triangle.2.circlepath.camera")
                            .labelStyle(.titleAndIcon)
                    }
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

    // MARK: Per-shot options

    @ViewBuilder
    private func options(for shot: Shot) -> some View {
        switch shot.shotKind {
        case .photo:
            EmptyView()
        case .document:
            Picker("Filter", selection: Binding(
                get: { shot.filter ?? .original },
                set: { value in camera.update(shotID) { $0.filter = value } }
            )) {
                ForEach(DocFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
        case .idPhoto:
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    ForEach(IDBackground.allCases) { bg in
                        Button {
                            camera.update(shotID) { $0.idBackground = bg }
                        } label: {
                            Circle()
                                .fill(Color(uiColor: bg.uiColor))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke((shot.idBackground ?? .white) == bg ? Color.yellow : Color.gray,
                                                         lineWidth: (shot.idBackground ?? .white) == bg ? 3 : 1))
                        }
                        .accessibilityLabel(bg.title)
                    }
                }
                Picker("Size", selection: Binding(
                    get: { shot.idSize ?? .passport },
                    set: { value in camera.update(shotID) { $0.idSize = value } }
                )) {
                    ForEach(IDSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding()
        }
    }
}
