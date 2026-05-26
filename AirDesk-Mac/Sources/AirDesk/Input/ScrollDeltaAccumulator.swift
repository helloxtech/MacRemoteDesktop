import CoreGraphics

struct ScrollDeltaAccumulator {
    private let scale: CGFloat
    private var remainders: [Int: CGPoint] = [:]

    init(scale: CGFloat) {
        self.scale = scale
    }

    mutating func consume(displayIndex: Int, deltaX: CGFloat, deltaY: CGFloat) -> (x: Int32, y: Int32) {
        let remainder = remainders[displayIndex] ?? .zero
        let accumulatedX = deltaX * scale + remainder.x
        let accumulatedY = deltaY * scale + remainder.y
        let wholeX = wholePart(of: accumulatedX)
        let wholeY = wholePart(of: accumulatedY)

        remainders[displayIndex] = CGPoint(
            x: accumulatedX - wholeX,
            y: accumulatedY - wholeY
        )

        return (Int32(wholeX), Int32(wholeY))
    }

    private func wholePart(of value: CGFloat) -> CGFloat {
        value >= 0 ? floor(value) : ceil(value)
    }
}
