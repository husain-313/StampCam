//  CameraModel.swift
//  Camera session, flash, zoom, capturing, the saved set of photos, and making the PDF.

import SwiftUI
import UIKit
import AVFoundation
import CoreLocation
import PDFKit

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
    private var position: AVCaptureDevice.Position = .back
    private var baseFactor: CGFloat = 1   // device zoom factor that equals "1x"
    // Keep the on-screen zoom and brightness in step when the Camera Control button changes them.
    private var zoomObservation: NSKeyValueObservation?
    private var biasObservation: NSKeyValueObservation?

    // The current set (main thread)
    @Published private(set) var shots: [Shot] = []
    /// Photos already handed to a PDF that is being made in the background.
    /// They stay saved (in case the app closes) but are no longer shown.
    @Published private(set) var hiddenIDs: Set<UUID> = []
    /// The photos in the current set (not counting ones going into a PDF).
    var visibleShots: [Shot] { hiddenIDs.isEmpty ? shots : shots.filter { !hiddenIDs.contains($0.id) } }
    /// True while a PDF is being made in the background.
    var isMakingPDF: Bool { !hiddenIDs.isEmpty }
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
    /// Brightness, from -2 (darker) to +2 (brighter). 0 = automatic.
    @Published private(set) var exposureBias: Float = 0
    /// Goes up when the camera goes back to automatic focus (e.g. the scene changed).
    @Published private(set) var focusResetCount = 0
    @Published private(set) var cameraDenied = false
    /// This iPhone has the Camera Control button (iPhone 16 and newer).
    @Published private(set) var hasCameraControl = false
    @Published private(set) var isFrontCamera = false
    /// Set when saving to Photos was turned on but access isn't allowed.
    @Published var photoAccessDenied = false

    // Status
    @Published private(set) var restoredCount = 0

    /// Set by the screen; used to tag photos with a location and area name.
    weak var location: LocationModel?
    /// Set by the camera preview; turns a tap on the screen into a point for the camera.
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private struct Slot {
        let id: UUID
        let date: Date
        let replaces: UUID?
        let coordinate: CLLocationCoordinate2D?
        let placeName: String?
        let heading: Double?
    }
    /// Photos being taken, by their capture id, so each photo gets its own date and place
    /// even when one fails or they finish out of order. Main thread only.
    private var pendingSlots: [Int64: Slot] = [:]

    override init() {
        let saved = FlashMode(rawValue: UserDefaults.standard.string(forKey: Keys.flashMode) ?? "") ?? .off
        _flash = Published(initialValue: saved)
        super.init()
        restoreSession()
        // When the scene changes a lot after tapping to focus, go back to automatic focus.
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.resetFocus()
        }
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
        useCamera(.back)
    }

    /// Switches between the back and front cameras.
    func toggleCamera() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sessionQueue.async {
            let next: AVCaptureDevice.Position = self.position == .back ? .front : .back
            self.useCamera(next)
        }
    }

    /// Runs on sessionQueue: puts the given camera into the session.
    private func useCamera(_ newPosition: AVCaptureDevice.Position) {
        let types: [AVCaptureDevice.DeviceType] = newPosition == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera, .builtInTrueDepthCamera]
        guard let dev = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: newPosition) }).first,
              let input = try? AVCaptureDeviceInput(device: dev) else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo
        for old in session.inputs { session.removeInput(old) }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        if #available(iOS 18.0, *) { installCameraControls(for: dev) }
        session.commitConfiguration()
        device = dev
        position = newPosition

        // Lens buttons (.5, 1, 2, 5) like the built-in Camera app (back camera only).
        let switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let hasTele = dev.constituentDevices.contains { $0.deviceType == .builtInTelephotoCamera }
        let base: CGFloat = hasUltraWide ? (switchOvers.first ?? 1) : 1

        var presets: [CGFloat] = []
        if newPosition == .back {
            if hasUltraWide && base > 1 { presets.append(1 / base) }
            presets.append(1)
            presets.append(2)
            if hasTele, let last = switchOvers.last {
                let tele = (last / base).rounded()
                if tele > 2 { presets.append(tele) }
            }
        } else {
            presets = [1]
        }

        let minDisplay = dev.minAvailableVideoZoomFactor / base
        let maxDisplay = min(dev.maxAvailableVideoZoomFactor / base, newPosition == .back ? 25 : 5)

        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = base
            dev.unlockForConfiguration()
        } catch {}
        baseFactor = base
        watchDevice(dev, base: base)

        DispatchQueue.main.async {
            self.zoomPresets = presets
            self.minZoom = minDisplay
            self.maxZoom = maxDisplay
            self.zoom = 1
            self.isFrontCamera = newPosition == .front
            self.exposureBias = 0
            self.focusResetCount += 1
        }
    }

    // MARK: Camera Control button (iPhone 16)

    /// Runs on sessionQueue, inside a configuration: slide on the Camera Control for zoom or brightness.
    @available(iOS 18.0, *)
    private func installCameraControls(for dev: AVCaptureDevice) {
        guard session.supportsControls else { return }
        DispatchQueue.main.async { self.hasCameraControl = true }
        if session.controlsDelegate == nil {
            session.setControlsDelegate(self, queue: sessionQueue)
        }
        for control in session.controls { session.removeControl(control) }
        let controls: [AVCaptureControl] = [
            AVCaptureSystemZoomSlider(device: dev),
            AVCaptureSystemExposureBiasSlider(device: dev)
        ]
        for control in controls where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    /// Follows the camera's zoom and brightness, whoever changes them (pinch, buttons or Camera Control).
    private func watchDevice(_ dev: AVCaptureDevice, base: CGFloat) {
        zoomObservation = dev.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            let display = device.videoZoomFactor / base
            DispatchQueue.main.async {
                guard let self, abs(self.zoom - display) > 0.01 else { return }
                self.zoom = display
            }
        }
        biasObservation = dev.observe(\.exposureTargetBias, options: [.new]) { [weak self] device, _ in
            let bias = device.exposureTargetBias
            DispatchQueue.main.async {
                guard let self, abs(self.exposureBias - bias) > 0.01 else { return }
                self.exposureBias = bias
            }
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

    // MARK: Focus & brightness

    /// Tap to focus: focuses and sets the brightness for that spot (a point in the preview).
    func focus(atPreviewPoint point: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        exposureBias = 0
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = devicePoint
                    dev.focusMode = .autoFocus
                }
                if dev.isExposurePointOfInterestSupported, dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposurePointOfInterest = devicePoint
                    dev.exposureMode = .continuousAutoExposure
                }
                dev.setExposureTargetBias(0, completionHandler: nil)
                dev.isSubjectAreaChangeMonitoringEnabled = true
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    /// Back to automatic focus and brightness for the whole picture (keeps the brightness slider value).
    func resetFocus() {
        focusResetCount += 1
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                let center = CGPoint(x: 0.5, y: 0.5)
                if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = center }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = center }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.isSubjectAreaChangeMonitoringEnabled = false
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    /// Makes the picture brighter (positive) or darker (negative).
    func setExposureBias(_ value: Float) {
        let clamped = min(max(value, -2), 2)
        exposureBias = clamped
        sessionQueue.async {
            guard let dev = self.device else { return }
            let safe = min(max(clamped, dev.minExposureTargetBias), dev.maxExposureTargetBias)
            do {
                try dev.lockForConfiguration()
                dev.setExposureTargetBias(safe, completionHandler: nil)
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: Capture

    /// `rotationAngle`: 90 portrait, 0 / 180 landscape, 270 upside down.
    func capture(rotationAngle: CGFloat = 90) {
        // Location at the moment of the shot (only if it's fresh).
        var coordinate: CLLocationCoordinate2D?
        var placeName: String?
        if let current = location?.current, Date().timeIntervalSince(current.timestamp) < 120 {
            coordinate = current.coordinate
            placeName = location?.cachedName(near: current)
        }

        let slot = Slot(id: UUID(), date: Date(), replaces: replaceTarget,
                        coordinate: coordinate, placeName: placeName,
                        heading: location?.heading)
        if let target = replaceTarget { replacingIDs.insert(target) }
        replaceTarget = nil
        let settings = AVCapturePhotoSettings()
        let captureID = settings.uniqueID
        pendingSlots[captureID] = slot
        pendingCount += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let flashMode = flash.avMode
        sessionQueue.async {
            guard let connection = self.output.connection(with: .video), connection.isEnabled else {
                DispatchQueue.main.async { self.dropSlot(captureID) }
                return
            }
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle   // upright in any orientation
            }
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
        let captureID = photo.resolvedSettings.uniqueID
        DispatchQueue.main.async {
            guard let slot = self.pendingSlots.removeValue(forKey: captureID) else { return }
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
        shot.heading = slot.heading
        return shot
    }

    /// Small preview of a photo (without the stamp).
    static func makeThumbnail(_ shot: Shot) -> UIImage? {
        SessionStore.thumbnail(shot.id)
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
                shot.heading = info.heading
                if let thumb { self.thumbnails[id] = thumb }
                self.shots.append(shot)
                self.persist()
                self.resolvePlaces()
            }
        }
    }

    private func dropSlot(_ captureID: Int64) {
        guard let slot = pendingSlots.removeValue(forKey: captureID) else { return }
        complete(slot, saved: false, thumbnail: nil)
    }

    private func complete(_ slot: Slot, saved: Bool, thumbnail: UIImage?) {
        pendingCount -= 1
        if let old = slot.replaces { replacingIDs.remove(old) }
        guard saved else { return }

        var shot = Self.newShot(from: slot)
        if let thumbnail { thumbnails[shot.id] = thumbnail }

        if let old = slot.replaces, let index = shots.firstIndex(where: { $0.id == old }) {
            // Retake: same position, and keep its note.
            shot.note = shots[index].note
            shots[index] = shot
            removeFiles(for: old)
        } else {
            shots.append(shot)               // new photo: at the end
        }
        persist()
        resolvePlaces()
    }

    // MARK: Editing the set

    /// Sets the note printed under a photo in the PDF (empty removes it).
    func setNote(_ id: UUID, _ text: String) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        shots[index].note = clean.isEmpty ? nil : String(clean.prefix(200))
        persist()
    }

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
    /// Photos added from the library get no stamp: only photos taken here show when and where.
    func stampLines(for shot: Shot) -> [String] {
        if shot.imported == true { return [] }
        return StampText.lines(date: shot.date, place: shot.placeName,
                               coordinate: shot.location?.coordinate, heading: shot.heading)
    }

    // MARK: PDF

    /// What happened after Done.
    struct PDFOutcome {
        /// The saved PDF (the existing one when adding to it), or nil if it failed.
        var url: URL?
        /// Photos that couldn't be read and stay in the camera.
        var leftOut = 0
        /// Adding to the existing PDF failed; the photos were saved as a new PDF instead.
        var appendFailed = false
    }

    /// Makes the PDF quietly in the background. The photos leave the camera at once;
    /// only the ones that made it into the saved PDF are deleted. The rest come back.
    /// [appendingTo]: the existing PDF these photos will be added to.
    func makePDF(appendingTo: URL?, completion: @escaping (PDFOutcome) -> Void) {
        let included = visibleShots
        guard !included.isEmpty else { completion(PDFOutcome()); return }
        let ids = Set(included.map(\.id))
        hiddenIDs.formUnion(ids)
        if let target = replaceTarget, ids.contains(target) { replaceTarget = nil }

        let wantsLocation = UserDefaults.standard.bool(forKey: Keys.showLocation)
        let locationUsable = !(location?.isDenied ?? true)
        resolvePlaces()
        let finish = {
            let current = self.shots.filter { ids.contains($0.id) }
            self.buildPDF(current, appendingTo: appendingTo, completion: completion)
        }
        if wantsLocation && locationUsable && included.contains(where: needsPlace) {
            // Give the area names a few seconds to arrive (nothing shown on screen).
            waitForPlaces(ids, until: Date().addingTimeInterval(4), then: finish)
        } else {
            finish()
        }
    }

    /// "Area – 14 Oct" from the first photo with an area name, or "Photos – 14 Oct".
    static func areaDateName(_ shots: [Shot]) -> String? {
        guard let first = shots.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        let date = formatter.string(from: first.date)
        let area = shots.lazy
            .compactMap(\.placeName)
            .map { $0.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "" }
            .first { !$0.isEmpty }
        return "\(area ?? "Photos") – \(date)"
    }

    /// Photos still waiting for their area name.
    private func needsPlace(_ shot: Shot) -> Bool {
        guard shot.placeName == nil else { return false }
        // A library photo without a saved location will never get one.
        return !(shot.imported == true && shot.location == nil)
    }

    private func waitForPlaces(_ ids: Set<UUID>, until deadline: Date, then done: @escaping () -> Void) {
        let waiting = shots.contains { ids.contains($0.id) && needsPlace($0) }
        if Date() >= deadline || !waiting {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.resolvePlaces()
            self.waitForPlaces(ids, until: deadline, then: done)
        }
    }

    private func buildPDF(_ included: [Shot], appendingTo: URL?, completion: @escaping (PDFOutcome) -> Void) {
        let ids = Set(included.map(\.id))
        let pages = included.map { PDFPageSource(shot: $0, lines: stampLines(for: $0)) }
        rememberStampedPlaces(included)

        let d = UserDefaults.standard
        let style = StampStyle.current()
        let quality = Quality(rawValue: d.string(forKey: Keys.quality) ?? "") ?? .medium
        let pageSize = PageSize(rawValue: d.string(forKey: Keys.pageSize) ?? "") ?? .photo

        let run: (Bool?) -> Void = { useAlbum in
          self.processQueue.async {
            // Also save each stamped photo to Photos (not ones that came from Photos).
            let saveToPhotos: ((Shot, Data) -> Void)? = useAlbum.map { album in
                { shot, data in
                    if shot.imported != true {
                        PhotoSaver.save(data, date: shot.date, location: shot.location, useAlbum: album)
                    }
                }
            }
            let built = PDFBuilder.build(pages, style: style, quality: quality, pageSize: pageSize,
                                         onPage: saveToPhotos) { _ in }
            var outcome = PDFOutcome()
            var firstNewPage = 0
            if let built {
                outcome.url = built.url
                // Adding to an existing PDF: merge here, in the background, so the screen never freezes.
                if let target = appendingTo {
                    if let basePages = FileStore.append(built.url, to: target) {
                        outcome.url = target
                        firstNewPage = basePages
                    } else {
                        outcome.appendFailed = true
                    }
                }
            }
            let finalURL = outcome.url
            DispatchQueue.main.async {
                self.hiddenIDs.subtract(ids)
                if let built {
                    // Only the photos that made it into the saved PDF leave the set.
                    // A photo that couldn't be read stays in the camera.
                    let saved = Set(built.written)
                    self.shots.removeAll { saved.contains($0.id) }
                    saved.forEach { self.thumbnails[$0] = nil }
                    self.persist()
                    outcome.leftOut = ids.count - saved.count
                    UINotificationFeedbackGenerator().notificationOccurred(outcome.leftOut == 0 ? .success : .warning)
                } else {
                    // Something went wrong: the photos are back in the camera.
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                completion(outcome)
            }

            // The PDF is already saved. Now read the text in the full-size photos (first 6)
            // for name suggestions, so small text is found even with Small quality. The rest
            // are read when the Rename screen opens. The text stays in the app (PDFText).
            guard let built, let url = finalURL else { return }
            let toRead = Array(built.written.prefix(6))
            let images = toRead.compactMap { TextScanner.image(at: SessionStore.imageURL($0), maxPixel: 2000) }
            if images.count == toRead.count {
                let reading = TextScanner.read(photos: images)
                PDFText.fill(url, pageCount: firstNewPage + built.written.count,
                             from: firstNewPage, lines: reading.pages,
                             names: PDFText.keepNames(reading.names, foundIn: reading.pages))
            }
            // Done with the originals. If the app closes before this, they're cleaned up at
            // the next launch (they're no longer in the saved set).
            built.written.forEach(SessionStore.deleteImage)
          }
        }

        if d.bool(forKey: Keys.saveToPhotos) {
            Task {
                let access = await PhotoSaver.requestAccess()
                await MainActor.run {
                    if !access.canSave { self.photoAccessDenied = true }
                    run(access.canSave ? access.album : nil)
                }
            }
        } else {
            run(nil)
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

// MARK: - Camera Control button

@available(iOS 18.0, *)
extension CameraModel: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
