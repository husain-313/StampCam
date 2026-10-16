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
