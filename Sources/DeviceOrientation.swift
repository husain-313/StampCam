//  DeviceOrientation.swift
//  Detects how the iPhone is held (portrait / landscape) from the motion sensors,
//  so it works even when the screen is locked to portrait — like the Camera app.

import Foundation
import CoreMotion
import CoreGraphics

final class DeviceOrientation: ObservableObject {
    enum Hold {
        case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
        // landscapeLeft  = phone turned to the left  (top of phone points left)
        // landscapeRight = phone turned to the right (top of phone points right)
    }

    @Published private(set) var hold: Hold = .portrait

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            // Ignore when the phone is lying flat or the tilt is unclear.
            let x = g.x, y = g.y
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

    /// Rotation for on-screen icons so they stay upright (the screen itself stays portrait).
    var iconAngle: Double {
        switch hold {
        case .portrait, .portraitUpsideDown: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        }
    }
}
