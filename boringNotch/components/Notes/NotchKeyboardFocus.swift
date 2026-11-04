//
//  NotchKeyboardFocus.swift
//  boringNotch
//
//  The notch window normally refuses keyboard focus so it never steals typing
//  from other apps. The Notes tab turns focus on while it's showing. While you're
//  typing, the notch stays open even if the mouse leaves it.
//

import AppKit

@MainActor
final class NotchKeyboardFocus {
    static let shared = NotchKeyboardFocus()

    /// Read by the notch windows' `canBecomeKey`.
    private(set) var allowsFocus = false
    /// True while a notch window has keyboard focus for editing.
    private(set) var isEditing = false

    /// The app you were in before clicking into a note; gets focus back afterwards.
    private var previousApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard Self.isNotchWindow(note.object) else { return }
            MainActor.assumeIsolated { NotchKeyboardFocus.shared.windowDidBecomeKey() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            guard Self.isNotchWindow(note.object) else { return }
            // You clicked into another app: stop editing, let the notch close normally.
            MainActor.assumeIsolated { NotchKeyboardFocus.shared.finishEditing(restoreFocus: false) }
        })
    }

    nonisolated private static func isNotchWindow(_ object: Any?) -> Bool {
        object is BoringNotchSkyLightWindow || object is BoringNotchWindow
    }

    /// The Notes tab appeared.
    func allow() {
        allowsFocus = true
    }

    /// The Notes tab went away (tab switch or notch closed).
    func disallow() {
        finishEditing(restoreFocus: true)
        allowsFocus = false
    }

    private func windowDidBecomeKey() {
        guard allowsFocus, !isEditing else { return }
        isEditing = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        SharingStateManager.shared.beginInteraction()
    }

    /// Ends typing: Esc, the Done button, switching tabs, or clicking elsewhere.
    func finishEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false

        // Stop the text field from taking key presses.
        for window in NSApp.windows where Self.isNotchWindow(window) && window.isKeyWindow {
            window.makeFirstResponder(nil)
        }
        if restoreFocus, let app = previousApp {
            app.activate()
        }
        previousApp = nil

        // Lets the notch close again when the mouse isn't over it.
        SharingStateManager.shared.endInteraction()
    }
}
