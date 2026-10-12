//  CameraScreen.swift
//  Main screen: preview, flash, zoom, shutter, last-photo thumbnail and Done.

import SwiftUI
import AVFoundation
import AVKit

struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var location = LocationModel()

    @AppStorage(Keys.showLocation) private var showLocation = true
    @AppStorage(Keys.shareAfterDone) private var shareAfterDone = true
    @AppStorage(Keys.askNameAfterDone) private var askNameAfterDone = true

    @State private var sheet: ActiveSheet?
    @State private var toast: String?
    @State private var blink = false
    @State private var pinchStart: CGFloat?
    @State private var isBuilding = false

    enum ActiveSheet: Identifiable {
        case settings, review, files, share(URL), rename(URL)
        var id: String {
            switch self {
            case .settings: return "settings"
            case .review: return "review"
            case .files: return "files"
            case .share(let url): return "share-\(url.absoluteString)"
            case .rename(let url): return "rename-\(url.absoluteString)"
            }
        }
    }

    private var totalCount: Int { camera.shots.count + camera.pendingCount }
    private var canFinish: Bool { !camera.shots.isEmpty && camera.pendingCount == 0 && !isBuilding }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .frame(height: 52)

                ZStack(alignment: .bottom) {
                    CameraPreview(session: camera.session)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipped()
                        .overlay(Color.black.opacity(blink ? 0.7 : 0).allowsHitTesting(false))
                        .gesture(pinchGesture)
                        .overlay(alignment: .top) { retakeBanner }
                        .overlay { toastView }

                    if camera.zoomPresets.count > 1 {
                        zoomBar.padding(.bottom, 14)
                    }
                }

                Spacer(minLength: 0)
                bottomBar.padding(.horizontal, 28)
                Spacer(minLength: 0)
            }
        }
        .modifier(HardwareShutter { if sheet == nil { shutter() } })
        .onAppear {
            let loc = location
            camera.locationText = { loc.placeName }
            camera.start()
        }
        .onChange(of: showLocation, initial: true) { _, on in
            if on { location.start() } else { location.stop() }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .settings:
                SettingsView(locationName: location.placeName)
            case .files:
                FilesView()
            case .review:
                ReviewView(camera: camera,
                           onRetake: { id in
                               camera.replaceTarget = id
                               sheet = nil
                           },
                           onCreatePDF: { createPDF() })
            case .share(let url):
                ShareSheet(url: url)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            case .rename(let url):
                RenameSheet(url: url) { finalURL in
                    sheet = nil
                    afterSaved(finalURL, delay: 0.5)
                }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            Button { camera.flash = camera.flash.next } label: {
                Image(systemName: camera.flash.icon)
                    .font(.title3)
                    .foregroundStyle(camera.flash == .on ? Color.yellow : Color.white)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button { sheet = .files } label: {
                Image(systemName: "folder")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: Zoom

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = camera.zoom }
                camera.setZoom((pinchStart ?? 1) * value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private var selectedPreset: Int {
        camera.zoomPresets.lastIndex { $0 <= camera.zoom + 0.01 } ?? 0
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(camera.zoomPresets.enumerated()), id: \.offset) { index, preset in
                let selected = index == selectedPreset
                Button { camera.setZoom(preset, animated: true) } label: {
                    Text(zoomLabel(selected ? camera.zoom : preset, selected: selected))
                        .font(.system(size: selected ? 13 : 12, weight: .bold))
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
            }
        }
        .padding(5)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .animation(.easeOut(duration: 0.15), value: selectedPreset)
    }

    private func zoomLabel(_ value: CGFloat, selected: Bool) -> String {
        let v = (value * 10).rounded() / 10
        var text = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v))
        if text.hasPrefix("0.") { text.removeFirst() }   // ".5"
        return selected ? text + "×" : text
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button { sheet = .review } label: { thumbnail }
                .disabled(totalCount == 0)

            Spacer()

            Button { shutter() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 80, height: 80)
                    Circle().fill(Color.white).frame(width: 66, height: 66)
                }
            }
            .buttonStyle(ShutterStyle())
            .disabled(isBuilding)

            Spacer()

            Button { createPDF() } label: {
                Group {
                    if isBuilding {
                        ProgressView().tint(.white)
                    } else {
                        Text("Done").font(.headline)
                    }
                }
                .foregroundStyle(canFinish ? Color.yellow : Color.gray)
                .frame(width: 60, height: 60)
            }
            .disabled(!canFinish)
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let last = camera.shots.last {
                    Image(uiImage: last.thumbnail).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.8), lineWidth: 2))

            if totalCount > 0 {
                Text("\(totalCount)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
                    .offset(x: 10, y: -10)
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var retakeBanner: some View {
        if let target = camera.replaceTarget,
           let index = camera.shots.firstIndex(where: { $0.id == target }) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                Text("Retaking photo \(index + 1)").font(.subheadline.bold())
                Spacer()
                Button("Cancel") { camera.replaceTarget = nil }
                    .font(.subheadline.bold())
                    .foregroundStyle(.yellow)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(12)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .transition(.opacity)
        }
    }

    // MARK: Actions

    private func shutter() {
        guard !isBuilding else { return }
        let retaking = camera.replaceTarget != nil
        camera.capture()

        blink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.2)) { blink = false }
        }
        if retaking {
            // Back to the review grid so you can see the replaced photo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sheet = .review }
        }
    }

    private func createPDF() {
        guard canFinish else { return }
        isBuilding = true
        let hadSheet = sheet != nil
        sheet = nil

        camera.makePDF { url in
            isBuilding = false
            guard let url else {
                showToast("Couldn't create PDF")
                return
            }
            if askNameAfterDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + (hadSheet ? 0.5 : 0)) {
                    sheet = .rename(url)
                }
            } else {
                afterSaved(url, delay: hadSheet ? 0.5 : 0)
            }
        }
    }

    /// After the PDF has its final name: share it or show a confirmation.
    private func afterSaved(_ url: URL, delay: Double) {
        if shareAfterDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                sheet = .share(url)
            }
        } else {
            showToast("PDF Saved ✓")
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Shutter press effect

struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Volume buttons / Camera Control take a photo (iOS 18+)

struct HardwareShutter: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}

// MARK: - Camera preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
