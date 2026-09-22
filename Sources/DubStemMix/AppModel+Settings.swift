import AppKit
import DubStemMixCore

/// User preferences (PRD § 5.12), kept in UserDefaults: they belong to this Mac, not to a project.
enum Preference {
    static let sendPreFader = "sends.preFader." // + SendBus.key
}

extension AppModel {
    // MARK: Audio status (device, sample rate, buffer, load)

    func refreshAudioStatus() {
        guard !isPreview else { return }
        audioDevice = engine.outputDevice?.name ?? "no output device"
        audioFormat = Self.kilohertz(engine.outputSampleRate) + (engine.bufferFrames.map { " · buffer \($0)" } ?? "")
    }

    /// 48000 → "48 kHz", 44100 → "44.1 kHz".
    static func kilohertz(_ rate: Double) -> String {
        let kilo = rate / 1000
        return kilo == kilo.rounded() ? "\(Int(kilo)) kHz" : String(format: "%.1f kHz", kilo)
    }

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
