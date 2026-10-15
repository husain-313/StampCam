//  CameraScreen.swift
//  Main screen: preview, flash, zoom, shutter, last-photo thumbnail and Done.

import SwiftUI
import AVFoundation
import AVKit
import PhotosUI

struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var location = LocationModel()
    @StateObject private var orientation = DeviceOrientation()

    @AppStorage(Keys.showLocation) private var showLocation = true
    @AppStorage(Keys.shareAfterDone) private var shareAfterDone = true
    @AppStorage(Keys.askNameAfterDone) private var askNameAfterDone = true
    @AppStorage(Keys.showDate) private var showDate = true
    @AppStorage(Keys.showTime) private var showTime = true
    @AppStorage(Keys.use24Hour) private var use24Hour = false
    @AppStorage(Keys.stampPosition) private var stampPosition = StampPosition.bottomRight.rawValue
    @AppStorage(Keys.stampSize) private var stampSize = Defaults.stampSize
    @AppStorage(Keys.stampColor) private var stampColor = StampColor.white.rawValue
    @AppStorage(Keys.stampNote) private var stampNote = ""
    @AppStorage(Keys.showCoordinates) private var showCoordinates = false
    @AppStorage(Keys.showHeading) private var showHeading = false

    @State private var sheet: ActiveSheet?
    @State private var toast: String?
    @State private var blink = false
    @State private var pinchStart: CGFloat?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var focusPoint: CGPoint?
    @State private var focusHide: DispatchWorkItem?
    @State private var biasStart: Float?
    @State private var thumbBounce = false
    @State private var dragMode: DragMode?
    @State private var previewWidth: CGFloat = 0
    @State private var dialActive = false
    @State private var dialStart: CGFloat = 1
    @State private var ignoreZoomTapsUntil = Date.distantPast
    @AppStorage("showGrid") private var showGrid = false
    @AppStorage(Keys.seenCameraTips) private var seenCameraTips = false
    @Environment(\.scenePhase) private var scenePhase

    enum ActiveSheet: Identifiable {
        case settings, review, files, share(URL), rename(URL, String?)
        var id: String {
            switch self {
            case .settings: return "settings"
            case .review: return "review"
            case .files: return "files"
            case .share(let url): return "share-\(url.absoluteString)"
            case .rename(let url, _): return "rename-\(url.absoluteString)"
            }
        }
    }

    /// What a one-finger drag on the picture does.
    enum DragMode { case brightness, lens }

    private var totalCount: Int { camera.visibleShots.count + camera.pendingCount }
    /// The phone is straight (grid on): gives a small click so you can feel it.
    private var isLevel: Bool { showGrid && !orientation.isFlat && abs(orientation.tilt) < 1 }
    /// Done is ready when there are photos and no PDF is still being made in the background.
    private var canFinish: Bool { !camera.visibleShots.isEmpty && camera.pendingCount == 0 && !camera.isMakingPDF }
    /// Location is needed for the area name, the coordinates or the direction.
    private var needsLocation: Bool { showLocation || showCoordinates || showHeading }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .frame(height: 52)

                CameraPreview(session: camera.session) { layer in camera.previewLayer = layer }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipped()
                        .background(GeometryReader { geo in
                            Color.clear
                                .onAppear { previewWidth = geo.size.width }
                                .onChange(of: geo.size.width) { _, w in previewWidth = w }
                        })
                        .gesture(pinchGesture)
                        .simultaneousGesture(focusTap)
                        .simultaneousGesture(flipTap)
                        .simultaneousGesture(previewDrag)
                        .overlay(Color.black.opacity(blink ? 0.7 : 0).allowsHitTesting(false))
                        .overlay { gridAndLevel }
                        .overlay { liveStamp }
                        .overlay { focusIndicator }
                        .overlay(alignment: .top) {
                            VStack(spacing: 0) {
                                appendBanner
                                retakeBanner
                            }
                        }
                        .overlay { toastView }
                        .overlay { cameraDeniedView }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 4)

                // Brightness, zoom and front/back below the preview, so nothing covers the stamp.
                ZStack {
                    if camera.zoomPresets.count > 1 { zoomControl }
                    brightnessChip
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                    flipButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 16)
                }
                .frame(height: 58)
                .padding(.top, 6)

                Spacer(minLength: 0)
                bottomBar.padding(.horizontal, 28)
                Spacer(minLength: 0)
            }

            if !seenCameraTips && !camera.cameraDenied && sheet == nil {
                CameraTips(hasCameraControl: camera.hasCameraControl) {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.25)) { seenCameraTips = true }
                }
                .transition(.opacity)
            }
        }
        .modifier(HardwareShutter { if sheet == nil { shutter() } })
        .onAppear {
            camera.location = location
            if camera.restoredCount > 0 {
                showToast(camera.restoredCount == 1
                          ? "Restored 1 photo from last time"
                          : "Restored \(camera.restoredCount) photos from last time")
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                camera.start()
                orientation.start()
                location.setHeadingWanted(showHeading)
                if needsLocation { location.start() }
                UIApplication.shared.isIdleTimerDisabled = true    // keep the screen on while shooting
            case .background:
                camera.stop()
                orientation.stop()
                location.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            default:
                break
            }
        }
        .onChange(of: needsLocation) { _, on in
            if on { location.start() } else { location.stop() }
        }
        .onChange(of: showHeading) { _, on in
            location.setHeadingWanted(on)
        }
        .onChange(of: orientation.hold, initial: true) { _, _ in
            location.setHeadingOrientation(orientation.headingOrientation)
        }
        .onChange(of: orientation.isSteep, initial: true) { _, steep in
            location.setHeadingPaused(steep)
        }
        .onChange(of: isLevel) { _, level in
            if level { Haptics.tick() }
        }
        .onChange(of: camera.focusResetCount) { _, _ in
            focusHide?.cancel()
            withAnimation(.easeOut(duration: 0.25)) { focusPoint = nil }
        }
        .onChange(of: camera.visibleShots.count) { old, new in
            guard new > old else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { thumbBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { thumbBounce = false }
            }
        }
        .onChange(of: location.updateCount) { _, _ in
            camera.resolvePlaces()
        }
        .onChange(of: camera.photoAccessDenied) { _, denied in
            if denied {
                camera.photoAccessDenied = false
                showToast("Allow Photos access in Settings to save there")
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            pickerItems = []
            Task {
                var added = 0
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        camera.importPhoto(data)
                        added += 1
                    }
                }
                if added > 0 {
                    showToast(added == 1 ? "1 photo added" : "\(added) photos added")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .settings:
                SettingsView(locationName: location.placeName)
                    .glassSheet()
            case .files:
                FilesView(onAddPhotos: { url in
                    camera.appendTarget = url
                    sheet = nil
                })
                .glassSheet()
            case .review:
                ReviewView(camera: camera,
                           onRetake: { id in
                               camera.replaceTarget = id
                               sheet = nil
                           },
                           onCreatePDF: { createPDF() })
                .glassSheet()
            case .share(let url):
                ShareSheet(url: url)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            case .rename(let url, let extra):
                RenameSheet(url: url, extraSuggestion: extra) { finalURL in
                    sheet = nil
                    afterSaved(finalURL, delay: 0.5)
                }
                .glassSheet()
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button {
                    Haptics.tap()
                    camera.flash = camera.flash.next
                } label: {
                    barIcon(camera.flash.icon, active: camera.flash == .on)
                }
                .accessibilityLabel("Flash")
                Button {
                    Haptics.tap()
                    showGrid.toggle()
                } label: {
                    barIcon("squareshape.split.3x3", active: showGrid)
                }
                .accessibilityLabel("Grid and level")
            }
            .padding(3)
            .glass(Capsule())

            Spacer(minLength: 4)
            if showLocation { locationPill }
            Spacer(minLength: 4)

            HStack(spacing: 2) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, matching: .images) {
                    barIcon("photo.on.rectangle")
                }
                .accessibilityLabel("Add from Photos")
                Button {
                    Haptics.tap()
                    sheet = .files
                } label: { barIcon("folder") }
                    .accessibilityLabel("Your PDFs")
                Button {
                    Haptics.tap()
                    sheet = .settings
                } label: { barIcon("gearshape") }
                    .accessibilityLabel("Settings")
            }
            .padding(3)
            .glass(Capsule())
        }
    }

    /// Icon used in the glass bars; turns yellow when it's on.
    private func barIcon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? Color.black : Color.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(active ? Color.yellow : Color.clear))
            .contentShape(Circle())
            .upright(orientation.iconAngle)
            .animation(.easeOut(duration: 0.15), value: active)
    }

    // MARK: Location status

    private var locationPill: some View {
        Button {
            if location.isDenied { openSettings() }
        } label: {
            HStack(spacing: 6) {
                if location.isDenied {
                    Image(systemName: "location.slash.fill")
                    Text("Location Off")
                } else if let name = location.placeName {
                    Image(systemName: "location.fill")
                    Text(name).lineLimit(1)
                } else {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Finding location…")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(location.isDenied ? Color.orange : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .glass(Capsule())
        }
        .disabled(!location.isDenied)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
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

    /// Lens buttons; press and hold, then slide, for a smooth zoom dial.
    private var zoomControl: some View {
        ZStack {
            if dialActive { zoomDial } else { zoomBar }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dialActive)
        .simultaneousGesture(dialGesture)
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(camera.zoomPresets.enumerated()), id: \.offset) { index, preset in
                let selected = index == selectedPreset
                Button {
                    // A release right after using the dial isn't a tap.
                    guard Date() > ignoreZoomTapsUntil else { return }
                    Haptics.tick()
                    camera.setZoom(preset, animated: true)
                } label: {
                    Text(zoomLabel(selected ? camera.zoom : preset, selected: selected))
                        .font(.system(size: selected ? 13 : 12, weight: .bold))
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(Circle().fill(Color.black.opacity(selected ? 0.35 : 0.2)))
                        .upright(orientation.iconAngle)
                }
            }
        }
        .padding(4)
        .glass(Capsule())
        .animation(.easeOut(duration: 0.15), value: selectedPreset)
    }

    private var zoomDial: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass")
            Text(String(format: "%.1f×", Double(camera.zoom)))
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(.yellow)
                .frame(minWidth: 52)
            Image(systemName: "plus.magnifyingglass")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glass(Capsule())
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// Press and hold the lens buttons, then slide right to zoom in and left to zoom out.
    private var dialGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !dialActive {
                    dialActive = true
                    dialStart = camera.zoom
                    Haptics.tap()
                }
                guard let drag else { return }
                let target = dialStart * CGFloat(exp(Double(drag.translation.width) / 140))
                let clamped = min(max(target, camera.minZoom), camera.maxZoom)
                // A click each time you pass a lens (.5, 1, 2, 5).
                if camera.zoomPresets.contains(where: { (camera.zoom < $0) != (clamped < $0) }) {
                    Haptics.tick()
                }
                camera.setZoom(clamped)
            }
            .onEnded { _ in
                guard dialActive else { return }
                dialActive = false
                ignoreZoomTapsUntil = Date().addingTimeInterval(0.4)
            }
    }

    /// Swipe left or right on the picture to change lens.
    private func switchLens(by step: Int) {
        let presets = camera.zoomPresets
        guard presets.count > 1 else { return }
        let next = min(max(selectedPreset + step, 0), presets.count - 1)
        guard next != selectedPreset else { return }
        Haptics.tick()
        camera.setZoom(presets[next], animated: true)
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
            Button {
                Haptics.tap()
                sheet = .review
            } label: { thumbnail.upright(orientation.iconAngle) }
                .disabled(totalCount == 0)
                .frame(width: 80, alignment: .leading)

            Spacer()

            Button { shutter() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 80, height: 80)
                    Circle().fill(Color.white).frame(width: 66, height: 66)
                        .scaleEffect(blink ? 0.85 : 1)
                }
                .shadow(color: .white.opacity(0.15), radius: 8)
            }
            .buttonStyle(ShutterStyle())
            .accessibilityLabel("Take Photo")

            Spacer()

            Button {
                Haptics.tap()
                createPDF()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
                .foregroundStyle(canFinish ? Color.black : Color.white.opacity(0.4))
                .frame(width: 76, height: 44)
                .modifier(DoneBackground(ready: canFinish))
                .upright(orientation.iconAngle)
                .animation(.easeOut(duration: 0.2), value: canFinish)
            }
            .disabled(!canFinish)
            .frame(width: 80, alignment: .trailing)
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let last = camera.visibleShots.last, let thumb = camera.thumbnails[last.id] {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.85), lineWidth: 1.5))

            if totalCount > 0 {
                Text("\(totalCount)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
                    .offset(x: 9, y: -9)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: totalCount)
            }
        }
        .scaleEffect(thumbBounce ? 1.12 : 1)
    }

    // MARK: Brightness

    /// Shows the brightness when it isn't automatic; tap to go back to automatic.
    @ViewBuilder
    private var brightnessChip: some View {
        if camera.exposureBias != 0 {
            Button {
                Haptics.tap()
                camera.setExposureBias(0)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                    Text(String(format: "%+.1f", camera.exposureBias)).monospacedDigit()
                }
                .font(.caption.bold())
                .foregroundStyle(.yellow)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glass(Capsule())
                .upright(orientation.iconAngle)
            }
            .accessibilityLabel("Brightness. Tap to reset")
            .transition(.opacity)
        }
    }

    // MARK: Tap to focus

    private var focusTap: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !camera.cameraDenied else { return }
                camera.focus(atPreviewPoint: value.location)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { focusPoint = value.location }
                scheduleFocusHide()
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
    }

    /// Double-tap the picture to switch between the back and front cameras.
    private var flipTap: some Gesture {
        TapGesture(count: 2).onEnded {
            guard !camera.cameraDenied else { return }
            camera.toggleCamera()
        }
    }

    /// One finger on the picture:
    /// - after tapping to focus, slide up or down for brightness;
    /// - swipe left or right to change lens (not from the very edge of the screen).
    private var previewDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard pinchStart == nil else { return }
                if dragMode == nil {
                    let dx = abs(value.translation.width), dy = abs(value.translation.height)
                    let nearEdge = value.startLocation.x < 20 || value.startLocation.x > previewWidth - 20
                    if focusPoint != nil && dy > dx {
                        dragMode = .brightness
                        biasStart = camera.exposureBias
                        focusHide?.cancel()
                    } else if dx > dy * 1.5 && !nearEdge {
                        dragMode = .lens
                    } else {
                        return
                    }
                }
                if dragMode == .brightness {
                    let delta = Float(-value.translation.height / 120)
                    camera.setExposureBias((biasStart ?? 0) + delta)
                }
            }
            .onEnded { value in
                switch dragMode {
                case .lens:
                    // Swipe left = closer, swipe right = wider.
                    if abs(value.translation.width) > 50 {
                        switchLens(by: value.translation.width < 0 ? 1 : -1)
                    }
                case .brightness:
                    biasStart = nil
                    scheduleFocusHide()
                case nil:
                    break
                }
                dragMode = nil
            }
    }

    private func scheduleFocusHide() {
        focusHide?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
        }
        focusHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Yellow focus square with a sun that moves with the brightness.
    @ViewBuilder
    private var focusIndicator: some View {
        if let point = focusPoint {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 74, height: 74)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .offset(y: CGFloat(-camera.exposureBias) * 18)
                    .frame(height: 74)
            }
            .shadow(color: .black.opacity(0.4), radius: 2)
            .position(x: point.x + 11, y: point.y)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 1.25)))
        }
    }

    // MARK: Front / back camera

    private var flipButton: some View {
        Button { camera.toggleCamera() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glass(Circle())
                .upright(orientation.iconAngle)
        }
        .accessibilityLabel(camera.isFrontCamera ? "Use back camera" : "Use front camera")
    }

    // MARK: Live stamp

    /// The stamp shown live on the camera, exactly where and how it will appear on the photo.
    @ViewBuilder
    private var liveStamp: some View {
        if !camera.cameraDenied && stampVisible {
            TimelineView(.everyMinute) { context in
                GeometryReader { geo in
                    let angle = orientation.iconAngle
                    let landscape = abs(angle) == 90
                    // The photo's own width and height (swapped when shooting sideways).
                    let w = landscape ? geo.size.height : geo.size.width
                    let h = landscape ? geo.size.width : geo.size.height
                    let position = StampPosition(rawValue: stampPosition) ?? .bottomRight
                    let color = StampColor(rawValue: stampColor) ?? .white
                    let fontSize = min(w, h) * stampSize

                    Text(liveLines(at: context.date).joined(separator: "\n"))
                        .font(.system(size: fontSize, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(position.isLeft ? .leading : .trailing)
                        .lineSpacing(fontSize * 0.15)
                        .foregroundStyle(color.color)
                        .shadow(color: color.shadow, radius: fontSize * 0.2)
                        .shadow(color: color.shadow, radius: fontSize * 0.2)
                        .padding(fontSize * 0.9)
                        .frame(width: w, height: h, alignment: position.alignment)
                        .rotationEffect(.degrees(angle))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.3), value: orientation.iconAngle)
        }
    }

    private var stampVisible: Bool {
        showDate || showTime || showLocation || showCoordinates || showHeading
            || !stampNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func liveLines(at date: Date) -> [String] {
        _ = (use24Hour, stampNote, showDate, showTime, showLocation, showCoordinates, showHeading)   // refresh when settings change
        return StampText.lines(date: date, place: location.placeName,
                               coordinate: location.current?.coordinate, heading: location.heading)
    }

    // MARK: Grid and level

    @ViewBuilder
    private var gridAndLevel: some View {
        if showGrid && !camera.cameraDenied {
            ZStack {
                GeometryReader { geo in
                    Path { p in
                        for i in 1...2 {
                            let x = geo.size.width * CGFloat(i) / 3
                            let y = geo.size.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
                }
                if !orientation.isFlat {
                    let level = abs(orientation.tilt) < 1
                    ZStack {
                        // Fixed marks on both sides
                        HStack(spacing: 96) {
                            Rectangle().frame(width: 18, height: 2)
                            Rectangle().frame(width: 18, height: 2)
                        }
                        .foregroundStyle(level ? Color.yellow : Color.white.opacity(0.8))
                        .rotationEffect(.degrees(orientation.iconAngle))
                        // Moving line that follows the horizon
                        Rectangle()
                            .frame(width: 90, height: 2)
                            .foregroundStyle(level ? Color.yellow : Color.white)
                            .rotationEffect(.degrees(orientation.iconAngle - orientation.tilt))
                    }
                    .animation(.easeOut(duration: 0.1), value: orientation.tilt)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var appendBanner: some View {
        if let target = camera.appendTarget {
            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.rectangle")
                Text("Adding to \(target.deletingPathExtension().lastPathComponent)")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Button("Cancel") {
                    Haptics.tap()
                    camera.appendTarget = nil
                }
                    .font(.subheadline.bold())
                    .foregroundStyle(.yellow)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glass(Capsule())
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var retakeBanner: some View {
        if let target = camera.replaceTarget,
           let index = camera.visibleShots.firstIndex(where: { $0.id == target }) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                Text("Retaking photo \(index + 1)").font(.subheadline.bold())
                Spacer()
                Button("Cancel") {
                    Haptics.tap()
                    camera.replaceTarget = nil
                }
                    .font(.subheadline.bold())
                    .foregroundStyle(.yellow)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glass(Capsule())
            .padding(12)
        }
    }

    @ViewBuilder
    private var cameraDeniedView: some View {
        if camera.cameraDenied {
            ZStack {
                Color.black
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Camera Access Is Off")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Allow camera access in Settings to take photos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") { openSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow)
                        .foregroundStyle(.black)
                }
                .padding(32)
            }
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
                .glass(Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    // MARK: Actions

    private func shutter() {
        let retaking = camera.replaceTarget != nil
        camera.capture(rotationAngle: orientation.captureAngle)

        blink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.2)) { blink = false }
        }
        if retaking {
            // Back to the review grid so you can see the replaced photo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sheet = .review }
        }
    }

    /// Done: the photos leave the camera at once and the PDF is made quietly in the
    /// background. The name sheet (or share sheet) appears when the PDF is ready.
    private func createPDF() {
        guard canFinish else { return }
        if sheet != nil { sheet = nil }

        let appendTo = camera.appendTarget
        camera.appendTarget = nil
        camera.makePDF(appendingTo: appendTo) { url, areaName in
            guard let url else {
                camera.appendTarget = appendTo
                showToast("Couldn't create PDF")
                return
            }
            // Something else may be open by now; close it first.
            let delay = sheet != nil ? 0.5 : 0
            if sheet != nil { sheet = nil }
            if let appendTo {
                // Adding to an existing PDF: merge, keep its name.
                if FileStore.append(url, to: appendTo) {
                    afterSaved(appendTo, delay: delay)
                } else {
                    showToast("Couldn't add to the PDF; saved as a new one")
                }
                return
            }
            if askNameAfterDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    sheet = .rename(url, areaName)
                }
            } else {
                afterSaved(url, delay: delay)
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
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
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
    /// Gives the preview layer to the camera (for tap to focus).
    var onLayer: (AVCaptureVideoPreviewLayer) -> Void = { _ in }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onLayer(view.previewLayer)
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

// MARK: - Keep icons upright when the phone turns

extension View {
    func upright(_ degrees: Double) -> some View {
        rotationEffect(.degrees(degrees))
            .animation(.easeInOut(duration: 0.3), value: degrees)
    }
}

// MARK: - Done button background: solid yellow when ready, glass when not

struct DoneBackground: ViewModifier {
    let ready: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if ready {
            content.background(Capsule().fill(Color.yellow))
        } else {
            content.glass(Capsule())
        }
    }
}
