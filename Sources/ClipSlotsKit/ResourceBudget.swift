import Foundation

/// Limits rebuildable caches, not business data or the live views' working set.
public final class ResourceBudget: @unchecked Sendable {
    public static let shared = ResourceBudget(monitorPressure: true)
    public enum Category: Int, CaseIterable {
        case slotBody, plainText, previewText, searchIndex, searchMetadata, searchContent
        case attachmentText, attachmentSummary, inlineFull, inlineThumb, mainThumb
        case canvasThumb, videoThumb, manualThumb, mediaMetadata, auxiliary
        var percent: Int {
            [24, 6, 1, 10, 4, 10, 3, 1, 12, 4, 8, 6, 3, 3, 2, 3][rawValue]
        }
    }
    public enum Pressure { case normal, warning, critical }
    private let lock = NSLock()
    private var overrideMiB = 0
    private var pressure: Pressure = .normal
    private var background = false
    private var lowPower = false
    private var observers: [UUID: () -> Void] = [:]
    private var source: DispatchSourceMemoryPressure?
    public let physicalMemory: UInt64

    public init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                monitorPressure: Bool = false) {
        self.physicalMemory = physicalMemory
        // Only the process singleton installs an OS source; isolated tests don't.
        if monitorPressure { startMonitoring() }
    }

    private func startMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "clipslots.resource.pressure", qos: .utility))
        source.setEventHandler { [weak self] in
            guard let flags = self?.source?.data else { return }
            self?.setPressure(flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal)
        }
        self.source = source
        source.resume()
    }

    public static func automaticMiB(for physicalMemory: UInt64) -> Int {
        physicalMemory <= 8 * 1024 * 1024 * 1024 ? 64
            : physicalMemory <= 16 * 1024 * 1024 * 1024 ? 128 : 256
    }
    public static func clampMiB(_ value: Int) -> Int { value == 0 ? 0 : min(512, max(32, value)) }
    public var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        let base = (overrideMiB == 0 ? Self.automaticMiB(for: physicalMemory) : overrideMiB) * 1024 * 1024
        let divisor = pressure == .critical ? 4 : pressure == .warning || background || lowPower ? 2 : 1
        return base / divisor
    }
    public func bytes(for category: Category) -> Int { totalBytes * category.percent / 100 }
    public var decodeConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return physicalMemory <= 16 * 1024 * 1024 * 1024 || pressure != .normal || background || lowPower ? 1 : 2
    }
    public var refreshInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return background ? 15 : pressure != .normal || lowPower ? 5 : 2
    }
    public var isBackground: Bool { lock.lock(); defer { lock.unlock() }; return background }

    public func configure(cacheMiB: Int) {
        change { overrideMiB = Self.clampMiB(cacheMiB) }
    }
    public func setPressure(_ value: Pressure) { change { pressure = value } }
    public func setActivity(background: Bool, lowPower: Bool) {
        change { self.background = background; self.lowPower = lowPower }
    }
    private func change(_ body: () -> Void) {
        lock.lock(); body(); let callbacks = Array(observers.values); lock.unlock()
        // Never hold the budget mutex while acquiring a cache mutex.
        callbacks.forEach { $0() }
    }
    @discardableResult
    public func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = callback; lock.unlock()
        return id
    }
    public func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
}

/// Byte-accounted LRU. Overlarge entries are returned to the caller but never retained.
/// One process-wide instance per category keeps allowances global across all groups.
public final class ResourceCache<Value>: @unchecked Sendable {
    private final class Entry {
        let key: AnyHashable
        let value: Value
        let cost: Int
        weak var previous: Entry?
        var next: Entry?
        init(_ key: AnyHashable, _ value: Value, _ cost: Int) {
            self.key = key; self.value = value; self.cost = cost
        }
    }
    private let lock = NSLock()
    private let budget: ResourceBudget
    private let category: ResourceBudget.Category
    private let countLimit: Int
    private var entries: [AnyHashable: Entry] = [:]
    private var first: Entry?
    private var last: Entry?
    private var used = 0
    private var observer: UUID?

    public init(category: ResourceBudget.Category, countLimit: Int = 8192,
                budget: ResourceBudget = .shared) {
        self.category = category; self.countLimit = countLimit; self.budget = budget
        observer = budget.observe { [weak self] in self?.trim() }
    }
    deinit { if let observer { budget.removeObserver(observer) } }
    public var totalCost: Int { lock.lock(); defer { lock.unlock() }; return used }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public func object(forKey key: AnyHashable) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        unlink(entry); append(entry)
        return entry.value
    }
    public func setObject(_ value: Value, forKey key: AnyHashable, cost: Int = 256) {
        lock.lock(); defer { lock.unlock() }
        let allowance = budget.bytes(for: category)
        if let old = entries.removeValue(forKey: key) { unlink(old); used -= old.cost }
        let keyBytes = (key.base as? NSString)?.length ?? 64
        let charged = max(0, cost) + keyBytes * 2 + 128
        guard charged <= allowance else { return }
        let entry = Entry(key, value, charged)
        entries[key] = entry; append(entry); used += charged
        evict(to: allowance)
    }
    public func removeObject(forKey key: AnyHashable) {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries.removeValue(forKey: key) { unlink(entry); used -= entry.cost }
    }
    public func removeAllObjects() {
        lock.lock(); entries.removeAll(); first = nil; last = nil; used = 0; lock.unlock()
    }
    public func removeAll() { removeAllObjects() }
    public func remove(where predicate: (AnyHashable) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        for key in Array(entries.keys) where predicate(key) {
            if let entry = entries.removeValue(forKey: key) { unlink(entry); used -= entry.cost }
        }
    }
    public func snapshot() -> [AnyHashable: Value] {
        lock.lock(); defer { lock.unlock() }
        return entries.mapValues(\.value)
    }
    public func trim() {
        lock.lock(); defer { lock.unlock() }
        evict(to: budget.bytes(for: category))
    }
    private func evict(to allowance: Int) {
        while used > allowance || entries.count > countLimit {
            guard let oldest = first else { break }
            entries.removeValue(forKey: oldest.key); unlink(oldest); used -= oldest.cost
        }
    }
    private func unlink(_ entry: Entry) {
        if let previous = entry.previous { previous.next = entry.next } else { first = entry.next }
        if let next = entry.next { next.previous = entry.previous } else { last = entry.previous }
        entry.previous = nil; entry.next = nil
    }
    private func append(_ entry: Entry) {
        entry.previous = last
        if let last { last.next = entry } else { first = entry }
        last = entry
    }
}

extension SlotContent {
    public var memoryCacheCost: Int {
        var cost = 512 + (htmlSource?.utf8.count ?? 0) * 2 + (pendingManualThumbnailData?.count ?? 0)
        for list in items {
            cost += 64
            for item in list { cost += item.data.count + item.type.utf8.count * 2 + 64 }
        }
        for attachment in attachments {
            cost += (attachment.data?.count ?? 0) + 256 + attachment.name.utf8.count * 2
            for value in [attachment.path, attachment.storagePath, attachment.url, attachment.originalPath] {
                cost += (value?.utf8.count ?? 0) * 2
            }
        }
        return cost
    }
}

final class SlotBodyMemoryCache {
    private static let shared = ResourceCache<SlotContent>(category: .slotBody)
    private let scope = UUID().uuidString + "::"
    subscript(slot: Int) -> SlotContent? {
        get { Self.shared.object(forKey: (scope + String(slot)) as NSString) }
        set {
            let key = (scope + String(slot)) as NSString
            if let newValue { Self.shared.setObject(newValue, forKey: key, cost: newValue.memoryCacheCost) }
            else { Self.shared.removeObject(forKey: key) }
        }
    }
    deinit { removeAll() }
    func removeAll() { Self.shared.remove { ($0.base as? NSString)?.hasPrefix(scope) == true } }
    func snapshot() -> [Int: SlotContent] {
        var result: [Int: SlotContent] = [:]
        for (key, value) in Self.shared.snapshot() {
            guard let name = key.base as? NSString, name.hasPrefix(scope),
                  let slot = Int(name.substring(from: scope.count)) else { continue }
            result[slot] = value
        }
        return result
    }
}
