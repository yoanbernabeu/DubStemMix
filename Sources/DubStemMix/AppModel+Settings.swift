import AppKit
import DubStemMixCore

/// User preferences (PRD § 5.12), kept in UserDefaults: they belong to this Mac, not to a project.
enum Preference {
    static let sendPreFader = "sends.preFader." // + SendBus.key
}

extension AppModel {
    // MARK: Pre/post-fader sends, per bus

    static func storedSendPreFader() -> [Bool] {
        SendBus.allCases.map { UserDefaults.standard.bool(forKey: Preference.sendPreFader + $0.key) }
    }

    func setSendPreFader(_ bus: SendBus, _ pre: Bool) {
        sendPreFader[bus.rawValue] = pre
        engine.setSendPreFader(bus, pre)
        UserDefaults.standard.set(pre, forKey: Preference.sendPreFader + bus.key)
    }
}
