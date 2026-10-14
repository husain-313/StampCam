//  Style.swift
//  The camera's look and feel: glass backgrounds and haptic feedback.

import SwiftUI
import UIKit

// MARK: - Haptics

/// Short, consistent vibrations for the camera controls.
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()

    /// A button was pressed.
    static func tap() { light.impactOccurred() }

    /// A value clicked to the next step (lens, level).
    static func tick() { selection.selectionChanged() }
}

// MARK: - Glass

/// Apple's Liquid Glass on iOS 26, and frosted glass (material) on older iOS.
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            frosted(content)
        }
        #else
        frosted(content)
        #endif
    }

    private func frosted(_ content: Content) -> some View {
        content
            .background(shape.fill(.ultraThinMaterial))
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.6))
    }
}

extension View {
    /// Puts the view on a glass background in the given shape.
    func glass<S: Shape>(_ shape: S) -> some View {
        modifier(GlassBackground(shape: shape))
    }
}

// MARK: - Glass sheets

extension View {
    /// Sheets over the camera use frosted glass, so the camera shows softly behind them.
    func glassSheet() -> some View {
        self
            .scrollContentBackground(.hidden)
            .presentationBackground(.ultraThinMaterial)
    }

    /// Rows in glass lists: a light see-through tint instead of solid gray.
    func glassRow() -> some View {
        listRowBackground(Color.white.opacity(0.08))
    }
}

// MARK: - First-run tips for the camera gestures

struct CameraTips: View {
    let hasCameraControl: Bool
    var onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("Camera Tips")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                tip("hand.draw", "Swipe left or right on the picture to change lens.")
                tip("plus.magnifyingglass", "Press and hold the lens buttons, then slide, to zoom smoothly.")
                tip("hand.tap", "Tap to focus. Then slide up or down for brightness.")
                tip("arrow.triangle.2.circlepath", "Double-tap the picture to switch cameras.")
                if hasCameraControl {
                    tip("camera.shutter.button", "Camera Control: press to take a photo. Slide on it for zoom or brightness.")
                }
                Button(action: onDone) {
                    Text("Got It")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(Color.yellow))
                }
                .padding(.top, 4)
            }
            .padding(24)
            .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 20)
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 30)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
