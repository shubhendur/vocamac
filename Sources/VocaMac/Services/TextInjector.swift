// TextInjector.swift
// VocaMac
//
// Injects transcribed text at the cursor position in any application
// using the clipboard (NSPasteboard) + simulated Cmd+V keystroke approach.

import Foundation
import AppKit

final class TextInjector {

    // MARK: - Constants

    /// Delay before restoring clipboard (seconds)
    private let clipboardRestoreDelay: Double = 2.0

    /// Virtual key code for the V key
    private let kVK_V: CGKeyCode = 9

    // MARK: - Types

    /// Deep copy of a single pasteboard item's data across all its types
    private struct PasteboardItemSnapshot {
        /// Map from pasteboard type to raw data
        let dataByType: [(NSPasteboard.PasteboardType, Data)]
    }

    /// Deep copy of the entire pasteboard state
    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    /// Injection strategy for text insertion.
    /// Used to keep clipboard handling consistent with the user toggle.
    enum InjectionMode: String {
        case clipboardPreserve
        case clipboardFallback
        case typing
    }

    // MARK: - Public API

    /// Inject text at the current cursor position in any application
    /// - Parameters:
    ///   - text: The text to inject
    ///   - preserveClipboard: Whether to save and restore the clipboard contents
    func inject(text: String, preserveClipboard: Bool = true) {
        guard !text.isEmpty else { return }

        // Check accessibility permission
        let trusted = AXIsProcessTrusted()
        VocaLogger.debug(.textInjector, "AXIsProcessTrusted = \(trusted ? "YES" : "NO")")
        VocaLogger.debug(.textInjector, "inject() called with preserveClipboard=\(preserveClipboard)")

        let mode = Self.injectionMode(preserveClipboard: preserveClipboard, isAccessibilityTrusted: trusted)
        switch mode {
        case .clipboardFallback:
            // Fix: without accessibility permission we must use the clipboard fallback.
            VocaLogger.warning(.textInjector, "No accessibility permission. Copying to clipboard only.")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .typing:
            // Fix: when clipboard preservation is OFF, avoid clipboard writes entirely.
            if !trusted {
                VocaLogger.warning(.textInjector, "Clipboard preservation OFF but Accessibility is not granted; typing may fail (clipboard remains untouched).")
            }
            VocaLogger.debug(.textInjector, "Clipboard preservation OFF - injecting via typing (no clipboard)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.simulateTyping(text)
            }
        case .clipboardPreserve:
            let pasteboard = NSPasteboard.general

            // Deep-copy current clipboard state before we overwrite it.
            // NSPasteboardItem objects are invalidated when the pasteboard is cleared,
            // so we must extract the raw data eagerly.
            let snapshot = captureSnapshot(pasteboard)
            VocaLogger.debug(.textInjector, "Snapshot captured: \(snapshot != nil ? "YES" : "NO") (preserveClipboard=\(preserveClipboard))")

            // Set transcribed text to clipboard
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            VocaLogger.debug(.textInjector, "Set clipboard: '\(String(text.prefix(80)))'")

            // Delay to let clipboard settle, then simulate Cmd+V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }

                VocaLogger.debug(.textInjector, "Simulating Cmd+V...")
                self.simulatePaste()

                // Clipboard preservation is ENABLED (toggle ON) - restore original clipboard after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) { [weak self] in
                    guard let self = self else { return }
                    if let snapshot = snapshot {
                        self.restoreSnapshot(snapshot, to: pasteboard)
                        VocaLogger.debug(.textInjector, "Restored original clipboard contents")
                    } else {
                        // Original clipboard was empty; clear the injected text to restore empty state
                        pasteboard.clearContents()
                        VocaLogger.debug(.textInjector, "Original clipboard was empty - clearing clipboard to restore empty state")
                    }
                }
            }
        }
    }

    // MARK: - Clipboard Snapshot Management

    /// Deep-copy every item and type from the pasteboard into plain `Data` values.
    /// This must be called *before* `clearContents()` because NSPasteboardItem
    /// objects are invalidated when the pasteboard changes.
    private func captureSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return nil
        }

        var itemSnapshots: [PasteboardItemSnapshot] = []

        for item in pasteboardItems {
            var dataByType: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType.append((type, data))
                }
            }
            if !dataByType.isEmpty {
                itemSnapshots.append(PasteboardItemSnapshot(dataByType: dataByType))
            }
        }

        guard !itemSnapshots.isEmpty else { return nil }
        return PasteboardSnapshot(items: itemSnapshots)
    }

    /// Write a previously captured snapshot back to the pasteboard.
    private func restoreSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        var newItems: [NSPasteboardItem] = []
        for itemSnapshot in snapshot.items {
            let newItem = NSPasteboardItem()
            for (type, data) in itemSnapshot.dataByType {
                newItem.setData(data, forType: type)
            }
            newItems.append(newItem)
        }

        pasteboard.writeObjects(newItems)
        VocaLogger.debug(.textInjector, "Restored clipboard with \(newItems.count) items")
    }

    // MARK: - Paste Simulation

    /// Simulate Cmd+V keystroke to paste from clipboard
    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Cmd+V key down
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: true) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create key down event")
            return
        }
        keyDown.flags = [.maskCommand]
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        // Cmd+V key up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: false) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create key up event")
            return
        }
        keyUp.flags = [.maskCommand]
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        VocaLogger.info(.textInjector, "Cmd+V posted")
    }

    /// Simulate typing text without using the clipboard.
    /// Uses Unicode keyboard events to insert text directly.
    private func simulateTyping(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create event source for typing")
            return
        }

        let utf16 = Array(text.utf16)
        let chunkSize = 512  // Avoid oversized unicode events
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            let chunk = Array(utf16[index..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                VocaLogger.error(.textInjector, "ERROR: Failed to create typing events")
                return
            }

            chunk.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            }

            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)

            index = end
        }

        VocaLogger.info(.textInjector, "Typed text via unicode events")
    }

    /// Decide how to inject text based on permissions and user setting.
    /// Internal for tests.
    static func injectionMode(
        preserveClipboard: Bool,
        isAccessibilityTrusted: Bool
    ) -> InjectionMode {
        if !preserveClipboard {
            // Never use clipboard when user explicitly disables preservation.
            return .typing
        }
        return isAccessibilityTrusted ? .clipboardPreserve : .clipboardFallback
    }
}
