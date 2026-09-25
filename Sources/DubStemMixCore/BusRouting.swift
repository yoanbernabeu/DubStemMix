import Foundation

/// Where each send bus's return is sent besides the master (issue #1): at most one other bus per source.
/// The routing always stays loop-free: AVAudioEngine cannot render a cycle, and a loop between effects
/// would run away anyway.
public struct BusRouting: Equatable, Sendable {
    public private(set) var targets: [SendBus: SendBus]

    /// A new session: every bus stands on its own, feeding only the master. Chaining buses is a choice.
    public static let standard = BusRouting()

    /// The routing of projects saved before the buses stood on their own: the delay fed the reverb (DLY→REV).
    public static let legacy = BusRouting(targets: [.delay: .reverb])

    public init(targets: [SendBus: SendBus] = [:]) {
        self.targets = targets.filter { $0.key != $0.value }
    }

    public func target(of source: SendBus) -> SendBus? { targets[source] }

    /// Whether `source` may send to `target` without closing a loop (its current target is replaced).
    public func allows(_ source: SendBus, to target: SendBus?) -> Bool {
        guard let target else { return true }
        guard target != source else { return false }
        var next: SendBus? = target
        var seen: Set<SendBus> = []
        while let bus = next, seen.insert(bus).inserted {
            if bus == source { return false }
            next = targets[bus]
        }
        return true
    }

    /// The routing with `source` sent to `target`, or nil when that would close a loop.
    public func setting(_ source: SendBus, to target: SendBus?) -> BusRouting? {
        guard allows(source, to: target) else { return nil }
        var copy = self
        copy.targets[source] = target
        return copy
    }

    public var isLoopFree: Bool {
        SendBus.allCases.allSatisfy { source in
            var next = targets[source]
            var steps = 0
            while let bus = next, steps <= SendBus.allCases.count {
                if bus == source { return false }
                next = targets[bus]
                steps += 1
            }
            return steps <= SendBus.allCases.count
        }
    }

    /// Stored in projects as `SendBus.key` → `SendBus.key` or "none", always: an absent value means `legacy`.
    public var projectValue: [String: String] {
        Dictionary(uniqueKeysWithValues: SendBus.allCases.map { ($0.key, targets[$0]?.key ?? "none") })
    }

    public init(projectValue: [String: String]?) {
        guard let projectValue else { self = .legacy; return }
        var targets: [SendBus: SendBus] = [:]
        for source in SendBus.allCases {
            if let key = projectValue[source.key], let target = SendBus.allCases.first(where: { $0.key == key }) {
                targets[source] = target
            }
        }
        let routing = BusRouting(targets: targets)
        self = routing.isLoopFree ? routing : .standard
    }
}

extension SendBus {
    /// Short name for knob labels ("DLY→REV"). The app names bus 3 after the effect it holds.
    public var shortName: String {
        switch self {
        case .delay: "DLY"
        case .reverb: "REV"
        case .bus3: "PHS"
        }
    }
}
