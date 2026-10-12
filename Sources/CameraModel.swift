//  CameraModel.swift
//  Camera session, flash, zoom, capturing and the list of photos in the current set.

import SwiftUI
import UIKit
import AVFoundation

// MARK: - A photo in the current set

struct Shot: Identifiable {
    let id: UUID
    let data: Data          // final JPEG (resized, stamped, compressed)
    let thumbnail: UIImage
}

// MARK: - Flash

enum FlashMode: String, CaseIterable {
    case off, auto, on

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    var icon: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        }
    }

    var next: FlashMode {
        switch self {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        }
    }
}

// MARK: - Camera

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let processQueue = DispatchQueue(label: "camera.process", qos: .userInitiated)

    // Used only on sessionQueue
    private var device: AVCaptureDevice?
    private var baseFactor: CGFloat = 1   // device zoom factor that equals "1x"

    // UI state (main thread)
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var replacingIDs: Set<UUID> = []
    @Published var replaceTarget: UUID?
    @Published var flash: FlashMode {
        didSet { UserDefaults.standard.set(flash.rawValue, forKey: Keys.flashMode) }
    }
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var zoomPresets: [CGFloat] = [1]
    @Published private(set) var minZoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 10

    /// Returns the current area name (set by the screen).
    var locationText: (() -> String?)?

    private struct Slot {
        let id: UUID
        let replaces: UUID?
        let options: CaptureOptions
    }
    private var pendingSlots: [Slot] = []   // main thread only

    override init() {
        let saved = FlashMode(rawValue: UserDefaults.standard.string(forKey: Keys.flashMode) ?? "") ?? .auto
        _flash = Published(initialValue: saved)
        super.init()
    }

    // MARK: Session

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    private func configureIfNeeded() {
        guard device == nil else { return }

        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        guard let dev = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
              let input = try? AVCaptureDeviceInput(device: dev) else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        device = dev

        // Work out the lens buttons (.5, 1, 2, 5) like the built-in Camera app.
        let switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let hasTele = dev.constituentDevices.contains { $0.deviceType == .builtInTelephotoCamera }
        let base: CGFloat = hasUltraWide ? (switchOvers.first ?? 1) : 1

        var presets: [CGFloat] = []
        if hasUltraWide && base > 1 { presets.append(1 / base) }
        presets.append(1)
        presets.append(2)
        if hasTele, let last = switchOvers.last {
            let tele = (last / base).rounded()
            if tele > 2 { presets.append(tele) }
        }

        let minDisplay = dev.minAvailableVideoZoomFactor / base
        let maxDisplay = min(dev.maxAvailableVideoZoomFactor / base, 25)

        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = base
            dev.unlockForConfiguration()
        } catch {}
        baseFactor = base

        DispatchQueue.main.async {
            self.zoomPresets = presets
            self.minZoom = minDisplay
            self.maxZoom = maxDisplay
            self.zoom = 1
        }
    }

    // MARK: Zoom

    /// `display` is the zoom shown to the user (1 = main lens).
    func setZoom(_ display: CGFloat, animated: Bool = false) {
        let value = min(max(display, minZoom), maxZoom)
        zoom = value
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                let factor = value * self.baseFactor
                if animated {
                    dev.ramp(toVideoZoomFactor: factor, withRate: 12)
                } else {
                    dev.cancelVideoZoomRamp()
                    dev.videoZoomFactor = factor
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: Capture

    func capture() {
        let slot = Slot(id: UUID(), replaces: replaceTarget, options: makeOptions())
        if let target = replaceTarget { replacingIDs.insert(target) }
        replaceTarget = nil
        pendingSlots.append(slot)
        pendingCount += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let flashMode = flash.avMode
        sessionQueue.async {
            guard let connection = self.output.connection(with: .video), connection.isEnabled else {
                DispatchQueue.main.async { self.dropOldestSlot() }
                return
            }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90   // portrait photos
            }
            let settings = AVCapturePhotoSettings()
            if self.output.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Reads the settings and location at the moment the shutter is pressed.
    private func makeOptions() -> CaptureOptions {
        let d = UserDefaults.standard
        var lines: [String] = []
        if d.bool(forKey: Keys.showTime) {
            lines.append(StampText.timeFormatter.string(from: Date()))
        }
        if d.bool(forKey: Keys.showLocation), let place = locationText?(), !place.isEmpty {
            lines.append(place)
        }
        let quality = Quality(rawValue: d.string(forKey: Keys.quality) ?? "") ?? .medium
        return CaptureOptions(lines: lines, style: StampStyle.current(), quality: quality)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            guard !self.pendingSlots.isEmpty else { return }
            let slot = self.pendingSlots.removeFirst()
            guard let image else {
                self.complete(slot, with: nil)
                return
            }
            self.processQueue.async {
                let result = ImageProcessor.process(image, options: slot.options)
                let shot = Shot(id: slot.id, data: result.data, thumbnail: result.thumbnail)
                DispatchQueue.main.async { self.complete(slot, with: shot) }
            }
        }
    }

    private func dropOldestSlot() {
        guard !pendingSlots.isEmpty else { return }
        complete(pendingSlots.removeFirst(), with: nil)
    }

    private func complete(_ slot: Slot, with shot: Shot?) {
        pendingCount -= 1
        if let old = slot.replaces { replacingIDs.remove(old) }
        guard let shot else { return }
        if let old = slot.replaces, let index = shots.firstIndex(where: { $0.id == old }) {
            shots[index] = shot          // retake: same position
        } else {
            shots.append(shot)           // new photo: at the end
        }
    }

    // MARK: Editing the set

    func delete(_ id: UUID) {
        shots.removeAll { $0.id == id }
        if replaceTarget == id { replaceTarget = nil }
    }

    // MARK: PDF

    func makePDF(completion: @escaping (URL?) -> Void) {
        let included = shots
        let ids = Set(included.map(\.id))
        let pageSize = PageSize(rawValue: UserDefaults.standard.string(forKey: Keys.pageSize) ?? "") ?? .photo
        processQueue.async {
            let url = PDFBuilder.build(included.map(\.data), pageSize: pageSize)
            DispatchQueue.main.async {
                if url != nil {
                    self.shots.removeAll { ids.contains($0.id) }
                    self.replaceTarget = nil
                }
                completion(url)
            }
        }
    }
}
