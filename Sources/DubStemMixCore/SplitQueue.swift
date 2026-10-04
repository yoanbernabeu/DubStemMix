import Foundation

/// The songs waiting to be split in the preparation mode (PRD § 12.6): one at a time, in the list's order.
/// Only waiting songs can be removed or reordered; finished ones stay in the list until the mode is left.
public struct SplitQueue: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waiting
        case running
        /// `reused`: the project file was already there, it was left untouched.
        case done(project: URL, reused: Bool)
        case failed(String)
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let source: URL
        /// Length of the song in seconds, for the time estimate (nil when the file can't be read).
        public let duration: Double?
        public var status: Status

        public init(source: URL, duration: Double?) {
            id = UUID()
            self.source = source
            self.duration = duration
            status = .waiting
        }

        public var isWaiting: Bool { status == .waiting }
    }

    public private(set) var items: [Item] = []

    public init() {}

    public var running: Item? { items.first { $0.status == .running } }
    public var waitingCount: Int { items.filter(\.isWaiting).count }
    /// Something is waiting or running: the mode can't be left.
    public var hasWork: Bool { items.contains { $0.isWaiting || $0.status == .running } }
    public var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    public var failedCount: Int { items.filter { if case .failed = $0.status { true } else { false } }.count }

    /// Appends the songs at the end; a file already waiting or running is not added twice.
    /// - Returns: how many were added.
    @discardableResult
    public mutating func add(_ songs: [(source: URL, duration: Double?)]) -> Int {
        var added = 0
        for song in songs {
            let source = song.source.standardizedFileURL
            guard !items.contains(where: { $0.source == source && ($0.isWaiting || $0.status == .running) }) else { continue }
            items.append(Item(source: source, duration: song.duration))
            added += 1
        }
        return added
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id && $0.isWaiting }
    }

    /// Moves a waiting song to the place of another waiting song (drag and drop).
    public mutating func move(_ id: UUID, onto target: UUID) {
        guard id != target,
              let from = items.firstIndex(where: { $0.id == id && $0.isWaiting }),
              let to = items.firstIndex(where: { $0.id == target && $0.isWaiting })
        else { return }
        items.insert(items.remove(at: from), at: to)
    }

    /// Moves a waiting song up (-1) or down (+1) among the waiting songs.
    public mutating func move(_ id: UUID, by offset: Int) {
        let waiting = items.filter(\.isWaiting).map(\.id)
        guard let index = waiting.firstIndex(of: id), waiting.indices.contains(index + offset) else { return }
        move(id, onto: waiting[index + offset])
    }

    /// The first waiting song, now running; nil when nothing waits (or one is already running).
    public mutating func startNext() -> Item? {
        guard running == nil, let index = items.firstIndex(where: \.isWaiting) else { return nil }
        items[index].status = .running
        return items[index]
    }

    public mutating func finish(_ id: UUID, _ status: Status) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    /// Stops everything: the running and waiting songs leave the list, the finished ones stay.
    public mutating func cancelAll() {
        items.removeAll { $0.isWaiting || $0.status == .running }
    }

    public mutating func removeAll() {
        items = []
    }

    /// Seconds left for the whole list: what remains of the running song plus the waiting ones, at the measured
    /// speed (seconds of work per second of audio). Nil until the speed is known. A song whose length can't be read
    /// counts for nothing: it won't be split (it fails at once).
    public func remainingTime(secondsPerAudioSecond speed: Double?, runningRemaining: Double?) -> Double? {
        guard let speed else { return nil }
        var total = 0.0
        if let running {
            total += runningRemaining ?? (running.duration ?? 0) * speed
        }
        for item in items where item.isWaiting {
            total += (item.duration ?? 0) * speed
        }
        return total
    }
}
