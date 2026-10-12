//  CameraModel.swift
//  Camera session, flash, zoom, capturing, the saved set of photos, and making the PDF.

import SwiftUI
import UIKit
import AVFoundation
import CoreLocation

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

    // The current set (main thread)
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published private(set) var pendingCount = 0
    @Published private(set) var replacingIDs: Set<UUID> = []
    @Published var replaceTarget: UUID?
    /// When set, Done adds the new photos to the end of this existing PDF.
    @Published var appendTarget: URL?

    // Camera controls
    @Published var flash: FlashMode {
        didSet { UserDefaults.standard.set(flash.rawValue, forKey: Keys.flashMode) }
    }
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var zoomPresets: [CGFloat] = [1]
    @Published private(set) var minZoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 10
    @Published private(set) var cameraDenied = false

    // Status
    @Published private(set) var restoredCount = 0
    @Published private(set) var waitingForLocation = false
    @Published private(set) var pdfDone = 0
    @Published private(set) var pdfTotal = 0

    /// Set by the screen; used to tag photos with a location and area name.
    weak var location: LocationModel?

    private struct Slot {
        let id: UUID
        let date: Date
        let replaces: UUID?
        let coordinate: CLLocationCoordinate2D?
        let placeName: String?
        let kind: ShotKind
    }
    private var pendingSlots: [Slot] = []   // main thread only

    override init() {
        let saved = FlashMode(rawValue: UserDefaults.standard.string(forKey: Keys.flashMode) ?? "") ?? .auto
        _flash = Published(initialValue: saved)
        super.init()
        restoreSession()
    }

    // MARK: Saved session

    private func restoreSession() {
        let saved = SessionStore.load()
        SessionStore.removeOrphans(keeping: Set(saved.map(\.id)))
        shots = saved
        restoredCount = saved.count
        processQueue.async {
            for shot in saved {
                guard let thumb = Self.makeThumbnail(shot) else { continue }
                DispatchQueue.main.async { self.thumbnails[shot.id] = thumb }
            }
        }
    }

    private func persist() {
        SessionStore.save(shots)
    }

    // MARK: Session

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            cameraDenied = true
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.cameraDenied = !granted }
            guard granted else { return }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    /// Pauses the camera (app in background) to save battery.
    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
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

        // Lens buttons (.5, 1, 2, 5) like the built-in Camera app.
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

    /// `rotationAngle`: 90 portrait, 0 / 180 landscape, 270 upside down.
    func capture(rotationAngle: CGFloat = 90, kind: ShotKind = .photo) {
        // Location at the moment of the shot (only if it's fresh).
        var coordinate: CLLocationCoordinate2D?
        var placeName: String?
        if let current = location?.current, Date().timeIntervalSince(current.timestamp) < 120 {
            coordinate = current.coordinate
            placeName = location?.cachedName(near: current)
        }

        let slot = Slot(id: UUID(), date: Date(), replaces: replaceTarget,
                        coordinate: coordinate, placeName: placeName, kind: kind)
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
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle   // upright in any orientation
            }
            let settings = AVCapturePhotoSettings()
            if self.output.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async {
            guard !self.pendingSlots.isEmpty else { return }
            let slot = self.pendingSlots.removeFirst()
            guard let data else {
                self.complete(slot, saved: false, thumbnail: nil)
                return
            }
            // Save the original photo to the iPhone right away.
            self.processQueue.async {
                let saved = SessionStore.writeImage(data, id: slot.id)
                let thumb = saved ? Self.makeThumbnail(Self.newShot(from: slot)) : nil
                DispatchQueue.main.async { self.complete(slot, saved: saved, thumbnail: thumb) }
            }
        }
    }

    private static func newShot(from slot: Slot) -> Shot {
        var shot = Shot(id: slot.id, date: slot.date,
                        latitude: slot.coordinate?.latitude,
                        longitude: slot.coordinate?.longitude,
                        placeName: slot.placeName)
        shot.kind = slot.kind
        if slot.kind == .idPhoto {
            let d = UserDefaults.standard
            shot.idBackground = IDBackground(rawValue: d.string(forKey: Keys.idBackground) ?? "") ?? .white
            shot.idSize = IDSize(rawValue: d.string(forKey: Keys.idSize) ?? "") ?? .passport
        }
        if slot.kind == .document { shot.filter = .original }
        return shot
    }

    /// Thumbnail showing the shot's final look (filter / new background), without the stamp.
    static func makeThumbnail(_ shot: Shot) -> UIImage? {
        switch shot.shotKind {
        case .photo:
            return SessionStore.thumbnail(shot.id)
        case .document, .idPhoto:
            return ShotRenderer.render(shot, lines: [], style: StampStyle.current(), maxDimension: 360)
        }
    }

    // MARK: Order

    /// Moves a photo to the position of another (drag and drop in the review grid).
    func move(_ id: UUID, to target: UUID) {
        guard id != target,
              let from = shots.firstIndex(where: { $0.id == id }),
              let to = shots.firstIndex(where: { $0.id == target }) else { return }
        let shot = shots.remove(at: from)
        shots.insert(shot, at: to)
        persist()
    }

    // MARK: Photos from the library

    /// Adds a photo from the library, using its own date and location when it has them.
    func importPhoto(_ data: Data) {
        let id = UUID()
        let info = PhotoInfo.read(data)
        pendingCount += 1
        processQueue.async {
            let saved = SessionStore.writeImage(data, id: id)
            let thumb = saved ? SessionStore.thumbnail(id) : nil
            DispatchQueue.main.async {
                self.pendingCount -= 1
                guard saved else { return }
                var shot = Shot(id: id, date: info.date ?? Date(),
                                latitude: info.coordinate?.latitude,
                                longitude: info.coordinate?.longitude,
                                placeName: nil)
                shot.imported = true
                if let thumb { self.thumbnails[id] = thumb }
                self.shots.append(shot)
                self.persist()
                self.resolvePlaces()
            }
        }
    }

    // MARK: Scanned documents

    /// Adds pages from the document scanner to the set.
    func addScannedPages(_ pages: [UIImage]) {
        guard !pages.isEmpty else { return }
        var coordinate: CLLocationCoordinate2D?
        var placeName: String?
        if let current = location?.current, Date().timeIntervalSince(current.timestamp) < 120 {
            coordinate = current.coordinate
            placeName = location?.cachedName(near: current)
        }
        let now = Date()
        let slots = pages.indices.map { i in
            Slot(id: UUID(), date: now.addingTimeInterval(Double(i) * 0.001), replaces: nil,
                 coordinate: coordinate, placeName: placeName, kind: .document)
        }
        pendingCount += pages.count
        processQueue.async {
            for (slot, page) in zip(slots, pages) {
                let data = page.jpegData(compressionQuality: 0.9)
                let saved = data.map { SessionStore.writeImage($0, id: slot.id) } ?? false
                let thumb = saved ? Self.makeThumbnail(Self.newShot(from: slot)) : nil
                DispatchQueue.main.async { self.complete(slot, saved: saved, thumbnail: thumb) }
            }
        }
    }

    /// Changes a shot's options (filter, background, size) and refreshes its thumbnail.
    func update(_ id: UUID, _ change: (inout Shot) -> Void) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        change(&shots[index])
        persist()
        let shot = shots[index]
        processQueue.async {
            let thumb = Self.makeThumbnail(shot)
            DispatchQueue.main.async { if let thumb { self.thumbnails[id] = thumb } }
        }
    }

    private func dropOldestSlot() {
        guard !pendingSlots.isEmpty else { return }
        complete(pendingSlots.removeFirst(), saved: false, thumbnail: nil)
    }

    private func complete(_ slot: Slot, saved: Bool, thumbnail: UIImage?) {
        pendingCount -= 1
        if let old = slot.replaces { replacingIDs.remove(old) }
        guard saved else { return }

        var shot = Self.newShot(from: slot)
        if let thumbnail { thumbnails[shot.id] = thumbnail }

        if let old = slot.replaces, let index = shots.firstIndex(where: { $0.id == old }) {
            // Retake: same position, and keep the options chosen for the old one.
            let previous = shots[index]
            if previous.shotKind == shot.shotKind {
                shot.filter = previous.filter
                shot.idBackground = previous.idBackground
                shot.idSize = previous.idSize
            }
            shots[index] = shot
            removeFiles(for: old)
            if shot.idBackground != Self.newShot(from: slot).idBackground || shot.idSize != Self.newShot(from: slot).idSize {
                update(shot.id) { _ in }     // refresh the thumbnail with the kept options
            }
        } else {
            shots.append(shot)               // new photo: at the end
        }
        persist()
        resolvePlaces()
    }

    // MARK: Editing the set

    func delete(_ id: UUID) {
        shots.removeAll { $0.id == id }
        if replaceTarget == id { replaceTarget = nil }
        removeFiles(for: id)
        persist()
    }

    private func removeFiles(for id: UUID) {
        thumbnails[id] = nil
        processQueue.async { SessionStore.deleteImage(id) }
    }

    // MARK: Location on every photo

    /// Fills in the location and area name for photos taken before they were ready.
    func resolvePlaces() {
        guard let location else { return }
        var changed = false

        for index in shots.indices where shots[index].placeName == nil {
            // Taken before the first location fix: use the first fix if it came within 5 minutes.
            // (Photos added from the library keep only their own location.)
            if shots[index].location == nil,
               shots[index].imported != true,
               let current = location.current,
               abs(current.timestamp.timeIntervalSince(shots[index].date)) < 300 {
                shots[index].latitude = current.coordinate.latitude
                shots[index].longitude = current.coordinate.longitude
                changed = true
            }
            guard let spot = shots[index].location else { continue }

            if let name = location.cachedName(near: spot) {
                shots[index].placeName = name
                changed = true
            } else {
                let id = shots[index].id
                location.requestName(for: spot) { [weak self] name in
                    guard let self, let name,
                          let i = self.shots.firstIndex(where: { $0.id == id }),
                          self.shots[i].placeName == nil else { return }
                    self.shots[i].placeName = name
                    self.persist()
                }
            }
        }
        if changed { persist() }
    }

    // MARK: Stamp

    /// The stamp lines for a photo, using the current settings.
    func stampLines(for shot: Shot) -> [String] {
        let d = UserDefaults.standard
        var lines: [String] = []
        switch shot.shotKind {
        case .idPhoto: return []
        case .document: if !d.bool(forKey: Keys.stampDocuments) { return [] }
        case .photo: break
        }
        if d.bool(forKey: Keys.showTime) {
            lines.append(StampText.timeFormatter.string(from: shot.date))
        }
        if d.bool(forKey: Keys.showLocation), let place = shot.placeName, !place.isEmpty {
            lines.append(place)
        }
        return lines
    }

    // MARK: PDF

    func makePDF(completion: @escaping (URL?) -> Void) {
        let wantsLocation = UserDefaults.standard.bool(forKey: Keys.showLocation)
        let locationUsable = !(location?.isDenied ?? true)
        let missing = shots.contains { needsPlace($0) }

        resolvePlaces()
        if wantsLocation && locationUsable && missing {
            // Give the area names a few seconds to arrive.
            waitingForLocation = true
            waitForPlaces(until: Date().addingTimeInterval(4)) {
                self.waitingForLocation = false
                self.buildPDF(completion: completion)
            }
        } else {
            buildPDF(completion: completion)
        }
    }

    /// Only photos (and documents, when they're stamped) need an area name.
    private func needsPlace(_ shot: Shot) -> Bool {
        guard shot.placeName == nil else { return false }
        // A library photo without a saved location will never get one.
        if shot.imported == true && shot.location == nil { return false }
        switch shot.shotKind {
        case .photo: return true
        case .document: return UserDefaults.standard.bool(forKey: Keys.stampDocuments)
        case .idPhoto: return false
        }
    }

    private func waitForPlaces(until deadline: Date, then done: @escaping () -> Void) {
        if Date() >= deadline || !shots.contains(where: { needsPlace($0) }) {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.resolvePlaces()
            self.waitForPlaces(until: deadline, then: done)
        }
    }

    private func buildPDF(completion: @escaping (URL?) -> Void) {
        let included = shots
        let ids = Set(included.map(\.id))
        let pages = included.map { PDFPageSource(shot: $0, lines: stampLines(for: $0)) }
        rememberStampedPlaces(included)

        let d = UserDefaults.standard
        let style = StampStyle.current()
        let quality = Quality(rawValue: d.string(forKey: Keys.quality) ?? "") ?? .medium
        let pageSize = PageSize(rawValue: d.string(forKey: Keys.pageSize) ?? "") ?? .photo

        pdfDone = 0
        pdfTotal = pages.count

        processQueue.async {
            let url = PDFBuilder.build(pages, style: style, quality: quality, pageSize: pageSize) { done in
                DispatchQueue.main.async { self.pdfDone = done }
            }
            DispatchQueue.main.async {
                self.pdfTotal = 0
                if url != nil {
                    // The PDF is safe; clear this set from the iPhone.
                    self.shots.removeAll { ids.contains($0.id) }
                    self.replaceTarget = nil
                    ids.forEach { self.removeFiles(for: $0) }
                    self.persist()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                completion(url)
            }
        }
    }

    /// Remembers printed area names so name suggestions can skip them.
    private func rememberStampedPlaces(_ shots: [Shot]) {
        let d = UserDefaults.standard
        var places = d.stringArray(forKey: Keys.stampedPlaces) ?? []
        for name in shots.compactMap(\.placeName) where !places.contains(name) {
            places.append(name)
        }
        d.set(Array(places.suffix(30)), forKey: Keys.stampedPlaces)
    }
}
