import AppKit
import SwiftUI

/// SwiftUI owns the title bar and toolbar layout. AppKit also needs a dark
/// backing color: its fullscreen toolbar can fall back to NSWindow's color
/// instead of the SwiftUI toolbar background.
struct WindowChromeAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.applyAppearance()
    }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func applyAppearance() {
            guard let window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(StudioTheme.surface)
        }
    }
}
