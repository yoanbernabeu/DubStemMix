import AppKit
import DubStemMixCore

/// User preferences (PRD § 5.12), kept in UserDefaults: they belong to this Mac, not to a project.
enum Preference {
    static let sendPreFader = "sends.preFader." // + SendBus.key
    static let outputDeviceUID = "audio.outputDeviceUID"
    static let bufferFrames = "audio.bufferFrames"
    static let recordingsFolder = "recording.folder"
}

extension AppModel {
    // MARK: Audio status (device, sample rate, buffer, load)

    func refreshAudioStatus() {
        guard !isPreview else { return }
        let device = engine.outputDevice
        audioDevice = device?.name ?? "no output device"
        audioFormat = Self.kilohertz(engine.outputSampleRate) + (engine.bufferFrames.map { " · buffer \($0)" } ?? "")
        outputDeviceUID = device?.uid ?? ""
        bufferFrames = engine.bufferFrames ?? 0
    }

    /// At launch: the device and buffer size chosen last time, when the device is still around.
    func applyStoredAudioPreferences() {
        let defaults = UserDefaults.standard
        if let uid = defaults.string(forKey: Preference.outputDeviceUID), let device = AudioDevices.device(uid: uid) {
            try? engine.setOutputDevice(device)
        }
        let frames = defaults.integer(forKey: Preference.bufferFrames)
        if frames > 0 { engine.setBufferFrames(frames) }
    }

    // MARK: Settings window

    func refreshOutputDevices() {
        guard !isPreview else { return }
        outputDevices = AudioDevices.outputDevices()
        refreshAudioStatus()
    }

    func selectOutputDevice(uid: String) {
        guard let device = outputDevices.first(where: { $0.uid == uid }) else { return }
        do {
            try engine.setOutputDevice(device)
            UserDefaults.standard.set(uid, forKey: Preference.outputDeviceUID)
            errorMessage = nil
        } catch {
            errorMessage = "Can't use \(device.name): \(error.localizedDescription)"
        }
        refreshAudioStatus()
    }

    /// The buffer size belongs to the device (shared by every app using it); the device may round the value.
    func selectBufferFrames(_ frames: Int) {
        if let applied = engine.setBufferFrames(frames) {
            UserDefaults.standard.set(applied, forKey: Preference.bufferFrames)
            errorMessage = nil
        } else {
            errorMessage = "The device refused a buffer of \(frames) samples"
        }
        refreshAudioStatus()
    }

    var bufferFrameRange: ClosedRange<Int>? {
        isPreview ? 14...4096 : AudioDevices.bufferFrameRange(of: engine.outputDeviceID)
    }

    func rescanPlugins() {
        installedPlugins = PluginInfo.installed()
    }

    // MARK: Recordings folder

    static let defaultRecordingsFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "DubStemMix")

    static func storedRecordingsFolder() -> URL {
        UserDefaults.standard.string(forKey: Preference.recordingsFolder).map { URL(fileURLWithPath: $0) } ?? defaultRecordingsFolder
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = recordingsFolder
        panel.message = "Choose where master recordings are saved"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        recordingsFolder = folder
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: Preference.recordingsFolder)
    }

    func resetRecordingsFolder() {
        recordingsFolder = Self.defaultRecordingsFolder
        UserDefaults.standard.removeObject(forKey: Preference.recordingsFolder)
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
