import CoreGraphics
import Foundation

@main
enum ScrollDeltaAccumulatorTests {
    static func main() {
        var accumulator = ScrollDeltaAccumulator(scale: 0.55)

        let firstSmallScroll = accumulator.consume(displayIndex: 0, deltaX: 0, deltaY: 1)
        expect(firstSmallScroll.x == 0 && firstSmallScroll.y == 0, "small scroll should be accumulated before emitting a line")

        let secondSmallScroll = accumulator.consume(displayIndex: 0, deltaX: 0, deltaY: 1)
        expect(secondSmallScroll.x == 0 && secondSmallScroll.y == 1, "two small positive deltas should emit one line")

        let largeScroll = accumulator.consume(displayIndex: 0, deltaX: 0, deltaY: 10)
        expect(largeScroll.x == 0 && largeScroll.y == 5, "large positive delta should be reduced by the scale factor")

        var negativeAccumulator = ScrollDeltaAccumulator(scale: 0.55)
        let firstNegativeScroll = negativeAccumulator.consume(displayIndex: 0, deltaX: 0, deltaY: -1)
        expect(firstNegativeScroll.x == 0 && firstNegativeScroll.y == 0, "small negative scroll should be accumulated before emitting a line")

        let secondNegativeScroll = negativeAccumulator.consume(displayIndex: 0, deltaX: 0, deltaY: -1)
        expect(secondNegativeScroll.x == 0 && secondNegativeScroll.y == -1, "two small negative deltas should emit one negative line")

        var displayAccumulator = ScrollDeltaAccumulator(scale: 0.55)
        _ = displayAccumulator.consume(displayIndex: 0, deltaX: 0, deltaY: 1)
        let otherDisplayScroll = displayAccumulator.consume(displayIndex: 1, deltaX: 0, deltaY: 1)
        expect(otherDisplayScroll.x == 0 && otherDisplayScroll.y == 0, "scroll remainders should be isolated per display")

        print("ScrollDeltaAccumulatorTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
