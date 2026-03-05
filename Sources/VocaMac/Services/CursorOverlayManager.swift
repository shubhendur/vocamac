// CursorOverlayManager.swift
// VocaMac
//
// Shows a floating mic indicator near the text cursor during recording.
// Uses the Accessibility API to locate the caret position in the focused app,
// then renders a small, non-interactive overlay that pulses with audio level.

import AppKit
import SwiftUI

// MARK: - CursorOverlayManager

@MainActor
final class CursorOverlayManager {

    // MARK: - Properties

    /// The floating panel that hosts the mic indicator
    private var overlayPanel: NSPanel?

    /// Hosting view for the SwiftUI indicator content
    private var hostingView: NSHostingView<MicIndicatorView>?

    /// The SwiftUI view model driving the indicator animation
    private let viewModel = MicIndicatorViewModel()

    /// Timer to periodically reposition the overlay to follow the cursor
    private var repositionTimer: Timer?

    // MARK: - Public API

    /// Show the recording indicator near the text cursor
    func show() {
        guard overlayPanel == nil else { return }

        let indicatorView = MicIndicatorView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: indicatorView)
        hosting.frame = NSRect(x: 0, y: 0, width: 36, height: 36)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = hosting

        // Position near the text cursor
        positionNearCaret(panel)

        panel.orderFront(nil)
        overlayPanel = panel
        hostingView = hosting

        // Reposition periodically in case the user scrolls or the cursor moves
        repositionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let panel = self.overlayPanel else { return }
                self.positionNearCaret(panel)
            }
        }

        viewModel.isActive = true
        NSLog("[CursorOverlay] Indicator shown")
    }

    /// Hide the recording indicator
    func hide() {
        repositionTimer?.invalidate()
        repositionTimer = nil
        viewModel.isActive = false
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        hostingView = nil
        NSLog("[CursorOverlay] Indicator hidden")
    }

    /// Update the audio level for the pulsing animation
    func updateAudioLevel(_ level: Float) {
        viewModel.audioLevel = level
    }

    // MARK: - Caret Position Detection

    /// Position the panel near the text caret using the Accessibility API.
    /// Falls back to positioning near the mouse cursor if the caret can't be found.
    private func positionNearCaret(_ panel: NSPanel) {
        if let caretRect = getCaretRect() {
            // Place the indicator just above and to the right of the caret
            let screenPoint = NSPoint(
                x: caretRect.origin.x + caretRect.width + 4,
                y: caretRect.origin.y + caretRect.height + 4
            )
            panel.setFrameOrigin(screenPoint)
        } else {
            // Fallback: position near the mouse cursor
            let mouseLocation = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(
                x: mouseLocation.x + 16,
                y: mouseLocation.y - 40
            ))
        }
    }

    /// Use the Accessibility API to get the bounding rect of the text caret
    /// in the currently focused application.
    private func getCaretRect() -> CGRect? {
        // Get the focused application
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        // Get the focused UI element (usually a text field)
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        let element = focusedElement as! AXUIElement

        // Get the selected text range (caret position)
        var selectedRange: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success else {
            return nil
        }

        // Get the bounds of the selected range (caret position on screen)
        var bounds: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRange!,
            &bounds
        ) == .success else {
            return nil
        }

        // Convert AXValue to CGRect
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else {
            return nil
        }

        // AX coordinates are top-left origin; convert to NSScreen bottom-left origin
        if let screen = NSScreen.main {
            rect.origin.y = screen.frame.height - rect.origin.y - rect.height
        }

        return rect
    }
}

// MARK: - MicIndicatorViewModel

@MainActor
final class MicIndicatorViewModel: ObservableObject {
    @Published var isActive: Bool = false
    @Published var audioLevel: Float = 0.0
}

// MARK: - MicIndicatorView

struct MicIndicatorView: View {
    @ObservedObject var viewModel: MicIndicatorViewModel

    var body: some View {
        ZStack {
            // Pulsing background circle
            Circle()
                .fill(Color.red.opacity(0.2))
                .frame(width: pulseSize, height: pulseSize)
                .animation(.easeInOut(duration: 0.3), value: viewModel.audioLevel)

            // Background circle
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 28, height: 28)
                .shadow(color: .red.opacity(0.4), radius: 4, x: 0, y: 0)

            // Mic icon
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
        .opacity(viewModel.isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isActive)
    }

    /// Size of the pulse circle, driven by audio level
    private var pulseSize: CGFloat {
        let base: CGFloat = 28
        let maxPulse: CGFloat = 36
        let level = CGFloat(min(max(viewModel.audioLevel, 0), 1))
        return base + (maxPulse - base) * level
    }
}
