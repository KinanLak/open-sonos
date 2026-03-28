import SwiftUI

struct SonosSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 100
    var disabled: Bool = false
    var height: CGFloat = 6

    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            let fillWidth = max(height, trackWidth * min(1, max(0, fraction)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(
                        disabled
                            ? Color.secondary.opacity(0.2)
                            : Color.accentColor.opacity(isHovering ? 0.9 : 0.65)
                    )
                    .frame(width: fillWidth)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard !disabled else { return }
                        let pct = max(0, min(1, drag.location.x / trackWidth))
                        value = (range.lowerBound + pct * span).rounded()
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: height)
        .opacity(disabled ? 0.5 : 1)
    }
}
