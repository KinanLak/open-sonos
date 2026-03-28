import AppKit
import SwiftUI

@MainActor
final class NowPlayingPanelController {
    private var panel: NowPlayingPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var dismissTask: Task<Void, Never>?
    private var isHovered = false

    private let dismissDelay: TimeInterval = 3.5

    weak var store: SonosStore?

    func show() {
        guard let store else { return }

        if panel == nil {
            createPanel(store: store)
        }

        if let panel, panel.isVisible, panel.alphaValue >= 1 {
            scheduleDismiss()
            return
        }

        updatePanelSize()
        positionPanel()

        panel?.alphaValue = 0
        panel?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel?.animator().alphaValue = 1
        }

        scheduleDismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        guard let panel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
            }
        })
    }

    func hoverChanged(_ isHovering: Bool) {
        isHovered = isHovering
        if isHovering {
            dismissTask?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    // MARK: - Private

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.dismissDelay ?? 3.5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.isHovered == true { return }
            self?.dismiss()
        }
    }

    private func createPanel(store: SonosStore) {
        let panel = NowPlayingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true

        let nowPlayingView = NowPlayingView(
            store: store,
            onInteraction: { [weak self] in self?.scheduleDismiss() },
            onHoverChanged: { [weak self] hovering in self?.hoverChanged(hovering) }
        )

        let hostingView = NSHostingView(rootView: AnyView(nowPlayingView))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        // Use maskImage instead of layer cornerRadius to avoid compositing
        // edge artifacts. When the effect view is the window's contentView,
        // maskImage is communicated directly to the window server so the blur
        // region itself is shaped correctly — no layer-level clipping needed.
        effectView.maskImage = Self.roundedRectMask(cornerRadius: 14)
        // No layer border — remove the explicit 0.5pt white outline.
        // If you later want a subtle border back, add it here.

        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        panel.contentView = effectView

        // Recompute the shadow from the actual visible shape after content is set.
        panel.invalidateShadow()

        self.panel = panel
        self.hostingView = hostingView
    }

    /// Creates a stretchable rounded-rect mask image for NSVisualEffectView.
    /// When set as `maskImage` on the window's contentView (an NSVisualEffectView),
    /// macOS communicates the shape to the window server so the blur region is
    /// composited correctly — avoiding the 1px edge artifact that `layer.cornerRadius`
    /// + `masksToBounds` produces.
    private static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * cornerRadius + 1.0
        let size = NSSize(width: edgeLength, height: edgeLength)
        let image = NSImage(size: size, flipped: false) { rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.set()
            bezierPath.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }

    private func updatePanelSize() {
        guard let panel, let hostingView else { return }
        let idealSize = hostingView.fittingSize
        let size = NSSize(width: max(300, idealSize.width), height: max(80, idealSize.height))
        panel.setContentSize(size)
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - panelSize.height - 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Custom Panel

private class NowPlayingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
