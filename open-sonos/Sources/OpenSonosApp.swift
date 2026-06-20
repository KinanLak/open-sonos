import Combine
import SwiftUI

@main
struct OpenSonosApp: App {
    @NSApplicationDelegateAdaptor(OpenSonosAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SonosMenuView(store: appDelegate.store)
                .onAppear { appDelegate.store.menuDidOpen() }
        } label: {
            MenuBarLabel(hasGroup: appDelegate.store.selectedGroup != nil,
                         isPlaying: appDelegate.store.selectedGroup?.isPlaying == true,
                         bpm: appDelegate.store.currentBPM,
                         fps: appDelegate.store.waveformFPS)
        }
        .menuBarExtraStyle(.window)

        Window("OpenSonos Settings", id: "settings") {
            SonosSettingsView(store: appDelegate.store, hotkeyManager: appDelegate.hotkeyManager)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menubar label with lightweight timer-driven waveform
// TimelineView(.animation) freezes the menubar, so we use Timer.publish at 12fps instead.

private struct MenuBarLabel: View {
    let hasGroup: Bool
    let isPlaying: Bool
    var bpm: Double? = nil
    var fps: Double = 10

    @State private var time: Double = 0

    var body: some View {
        let tick = Timer.publish(every: 1.0 / fps, on: .main, in: .common).autoconnect()
        if hasGroup {
            Image(nsImage: renderWaveform())
                .onReceive(tick) { _ in
                    guard isPlaying else { return }
                    time += 1.0 / fps
                }
        } else {
            Image(nsImage: renderWaveform())
        }
    }

    // MARK: - Render waveform as NSImage template

    private static let defaultConfigs: [(f1: Double, f2: Double, p1: Double, p2: Double)] = [
        (1.20, 1.56, 0.00, 2.10),
        (1.80, 2.34, 0.80, 0.60),
        (1.50, 1.95, 1.60, 1.30),
        (2.00, 2.60, 0.40, 2.80),
        (1.35, 1.76, 1.20, 0.90),
    ]

    private static let barOffsets: [Double] = [0.0, 0.08, 0.16, 0.06, 0.12]
    private static let barAmplitudes: [Double] = [0.75, 1.0, 0.85, 0.95, 0.70]

    private static let staticHeights: [CGFloat] = [4, 8, 14, 6, 10]

    private func renderWaveform() -> NSImage {
        let barWidth: CGFloat = 2.5
        let spacing: CGFloat = 1.5
        let maxHeight: CGFloat = 16
        let count = 5
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing

        let image = NSImage(size: NSSize(width: totalWidth, height: maxHeight))
        image.lockFocus()
        NSColor.black.setFill()

        for i in 0..<count {
            let h = barHeight(for: i, maxHeight: maxHeight)
            let x = CGFloat(i) * (barWidth + spacing)
            let y = (maxHeight - h) / 2
            let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                                    xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }

        image.unlockFocus()
        image.isTemplate = true // adapts to menubar light/dark automatically
        return image
    }

    private func barHeight(for index: Int, maxHeight: CGFloat) -> CGFloat {
        guard isPlaying else { return Self.staticHeights[index] }

        let minH: CGFloat = 2

        if let bpm {
            // BPM-synced: sharp pulse on each beat
            let bps = bpm / 60.0
            let offset = Self.barOffsets[index]
            let amp = Self.barAmplitudes[index]
            let beatPhase = (time * bps + offset).truncatingRemainder(dividingBy: 1.0)
            let pulse = pow(max(0, 1.0 - beatPhase * 2.0), 2.5)
            let organic = sin(time * 1.7 + Double(index) * 1.3) * 0.1
            let value = min(max(pulse * amp + organic, 0), 1)
            return minH + (maxHeight - minH) * value
        } else {
            let cfg = Self.defaultConfigs[index]
            let wave1 = sin(time * cfg.f1 * .pi * 2 + cfg.p1)
            let wave2 = sin(time * cfg.f2 * .pi * 2 + cfg.p2) * 0.35
            let combined = (wave1 + wave2 + 1.35) / 2.7
            return minH + (maxHeight - minH) * combined
        }
    }
}
