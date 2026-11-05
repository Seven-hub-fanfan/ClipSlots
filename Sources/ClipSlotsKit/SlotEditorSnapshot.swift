import Foundation

/// An editor owns a concrete page/group incarnation and a full body/attachment
/// snapshot. Rendering caches and the currently selected group are never writers.
public struct SlotEditorSnapshot {
    public let slot: Int
    public let group: SpecialSlot
    public let pageName: String
    public let content: SlotContent

    public init(slot: Int, group: SpecialSlot, pageName: String, content: SlotContent) {
        self.slot = slot
        self.group = group
        self.pageName = pageName
        self.content = content
    }
}
