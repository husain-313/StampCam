//  DeviceOrientation.swift
//  Detects how the iPhone is held (portrait / landscape) from the motion sensors,
//  so it works even when the screen is locked to portrait — like the Camera app.

import Foundation
import CoreMotion
import CoreGraphics
import CoreLocation

final class DeviceOrientation: ObservableObject {
    enum Hold {
        case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
        // landscapeLeft  = phone turned to the left  (top of phone points left)
        // landscapeRight = phone turned to the right (top of phone points right)
    }

    @Published private(set) var hold: Hold = .portrait
    /// How far the phone is tilted from level, in degrees (for the level indicator).
    @Published private(set) var tilt: Double = 0
    /// True when the phone is lying flat (the level is hidden then).
    @Published private(set) var isFlat = false

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            let x = g.x, y = g.y

            // Level: angle between gravity and "down" for the way the phone is held.
            let flat = abs(g.z) > 0.9
            if flat != self.isFlat { self.isFlat = flat }
            let down: (Double, Double)
            switch self.hold {
            case .portrait: down = (0, -1)
            case .portraitUpsideDown: down = (0, 1)
            case .landscapeLeft: down = (-1, 0)
            case .landscapeRight: down = (1, 0)
            }
            let angle = atan2(down.0 * y - down.1 * x, down.0 * x + down.1 * y) * 180 / .pi
            if abs(angle - self.tilt) > 0.2 { self.tilt = angle }

            // Ignore when the phone is lying flat or the tilt is unclear.
            guard max(abs(x), abs(y)) > 0.55 else { return }

            let newHold: Hold
            if abs(y) >= abs(x) {
                newHold = y < 0 ? .portrait : .portraitUpsideDown
            } else {
                newHold = x < 0 ? .landscapeLeft : .landscapeRight
            }
            if newHold != self.hold { self.hold = newHold }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Rotation for the back camera's photo so it comes out upright.
    var captureAngle: CGFloat {
        switch hold {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        }
    }

    /// For the compass, so the direction is the way the camera faces.
    var headingOrientation: CLDeviceOrientation {
        switch hold {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }

    /// Rotation for on-screen icons so they stay upright (the screen itself stays portrait).
    var iconAngle: Double {
        switch hold {
        case .portrait, .portraitUpsideDown: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        }
    }
}
