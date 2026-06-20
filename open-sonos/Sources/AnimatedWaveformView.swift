import SwiftUI

struct AnimatedWaveformView: View {
    var isAnimating: Bool
    var color: Color = .accentColor
    var barCount: Int = 5
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 1.5
    var maxHeight: CGFloat = 12
    var bpm: Double?
    var fps: Double?

    // Default frequencies for generic (non-BPM) animation.
    private static let defaultConfigs: [(freq1: Double, freq2: Double, phase1: Double, phase2: Double)] = [
        (1.20, 1.56, 0.00, 2.10),
        (1.80, 2.34, 0.80, 0.60),
        (1.50, 1.95, 1.60, 1.30),
        (2.00, 2.60, 0.40, 2.80),
        (1.35, 1.76, 1.20, 0.90),
    ]

    // Per-bar phase offsets for BPM mode — creates a "wave" across the bars.
    private static let barOffsets: [Double] = [0.0, 0.08, 0.16, 0.06, 0.12]

    // Per-bar amplitude variation so bars don't all hit the same max.
    private static let barAmplitudes: [Double] = [0.75, 1.0, 0.85, 0.95, 0.70]

    var body: some View {
        let minHeight = barWidth

        TimelineView(.animation(minimumInterval: fps.map { 1.0 / $0 }, paused: !isAnimating)) { timeline in
            HStack(alignment: .center, spacing: spacing) {
                let time = isAnimating
                    ? timeline.date.timeIntervalSinceReferenceDate
                    : 0.0

                ForEach(0..<barCount, id: \.self) { index in
                    let h = barHeight(for: index, at: time, min: minHeight, max: maxHeight)
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(color)
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(height: maxHeight)
            .animation(.easeInOut(duration: 0.45), value: isAnimating)
        }
    }

    private func barHeight(for index: Int, at time: Double, min: CGFloat, max: CGFloat) -> CGFloat {
        guard isAnimating else { return min }

        if let bpm {
            return bpmBarHeight(for: index, at: time, bpm: bpm, min: min, max: max)
        } else {
            return genericBarHeight(for: index, at: time, min: min, max: max)
        }
    }

    /// BPM-synced: sharp pulse on each beat with a wave across bars.
    private func bpmBarHeight(for index: Int, at time: Double, bpm: Double, min: CGFloat, max: CGFloat) -> CGFloat {
        let bps = bpm / 60.0
        let offset = Self.barOffsets[index % Self.barOffsets.count]
        let amp = Self.barAmplitudes[index % Self.barAmplitudes.count]

        // Phase within the current beat (0 → 1)
        let beatPhase = (time * bps + offset).truncatingRemainder(dividingBy: 1.0)

        // Sharp attack, smooth decay — like a real beat pulse
        let pulse = pow(Swift.max(0, 1.0 - beatPhase * 2.0), 2.5)

        // Subtle secondary motion so it's not perfectly mechanical
        let organic = sin(time * 1.7 + Double(index) * 1.3) * 0.1

        let value = (pulse * amp + organic).clamped(to: 0...1)
        return min + (max - min) * value
    }

    /// Generic smooth sine animation (no BPM).
    private func genericBarHeight(for index: Int, at time: Double, min: CGFloat, max: CGFloat) -> CGFloat {
        let cfg = Self.defaultConfigs[index % Self.defaultConfigs.count]
        let wave1 = sin(time * cfg.freq1 * .pi * 2 + cfg.phase1)
        let wave2 = sin(time * cfg.freq2 * .pi * 2 + cfg.phase2) * 0.35
        let combined = (wave1 + wave2 + 1.35) / 2.7
        return min + (max - min) * combined
    }
}

// MARK: - Convenience presets

extension AnimatedWaveformView {
    static func small(isAnimating: Bool, color: Color = .accentColor, bpm: Double? = nil, fps: Double? = nil) -> AnimatedWaveformView {
        AnimatedWaveformView(
            isAnimating: isAnimating,
            color: color,
            barCount: 5,
            barWidth: 1.5,
            spacing: 1,
            maxHeight: 10,
            bpm: bpm,
            fps: fps
        )
    }

    static func medium(isAnimating: Bool, color: Color = .accentColor, bpm: Double? = nil, fps: Double? = nil) -> AnimatedWaveformView {
        AnimatedWaveformView(
            isAnimating: isAnimating,
            color: color,
            barCount: 5,
            barWidth: 2.5,
            spacing: 2,
            maxHeight: 16,
            bpm: bpm,
            fps: fps
        )
    }

    static func menuBar(isAnimating: Bool, bpm: Double? = nil, fps: Double? = nil) -> AnimatedWaveformView {
        AnimatedWaveformView(
            isAnimating: isAnimating,
            color: .primary,
            barCount: 5,
            barWidth: 1.5,
            spacing: 1,
            maxHeight: 12,
            bpm: bpm,
            fps: fps
        )
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
