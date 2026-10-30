import Foundation

/// A failed/cancelled read must not be reported as a proven empty result.
/// This contains display/search data only and provides no mutation authority.
public struct SlotSearchReadResult {
    public let slots: [Int: SlotContent]
    public let isComplete: Bool

    public init(slots: [Int: SlotContent], isComplete: Bool) {
        self.slots = slots
        self.isComplete = isComplete
    }

    static var incomplete: Self { .init(slots: [:], isComplete: false) }
}
