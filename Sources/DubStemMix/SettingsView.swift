import DubStemMixCore
import StemSplit
import SwiftUI

/// Settings window (⌘,), PRD § 5.12: output device and buffer size, recordings folder,
/// pre/post-fader sends per bus, Audio Unit plugins.
struct SettingsView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            audio
            sends
            recording
            plugins
            separation
        }
        .padding(26)
        .frame(width: 480, alignment: .leading)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
        .onAppear {
            model.refreshOutputDevices()
            model.refreshModelStatus()
        }
    }

    // MARK: Audio

    private var audio: some View {
        SettingsSection(title: "AUDIO") {
            SettingsRow(label: "OUTPUT") {
                Menu {
                    ForEach(model.outputDevices) { device in
                        Button((device.uid == model.outputDeviceUID ? "✓ " : "") + device.name) { model.selectOutputDevice(uid: device.uid) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.audioDevice)
                            .font(Fonts.label(13, weight: 700, width: 105))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isPreview)
            }
            SettingsRow(label: "BUFFER") {
                HStack(spacing: 4) {
                    ForEach(bufferChoices, id: \.self) { frames in
                        SettingsChip(text: "\(frames)", active: frames == model.bufferFrames) { model.selectBufferFrames(frames) }
                    }
                    if !bufferChoices.contains(model.bufferFrames), model.bufferFrames > 0 {
                        SettingsChip(text: "\(model.bufferFrames)", active: true) {}
                    }
                }
            }
            SettingsNote(model.audioFormat.isEmpty ? " " : "\(model.audioFormat) samples · the buffer size belongs to the device and applies to every app using it")
        }
    }

    private var bufferChoices: [Int] {
        guard let range = model.bufferFrameRange else { return AudioDevices.bufferChoices }
        return AudioDevices.bufferChoices.filter { range.contains($0) }
    }

    // MARK: Sends

    private var sends: some View {
        SettingsSection(title: "SENDS") {
            ForEach(Bus.allCases, id: \.self) { bus in
                let pre = model.sendPreFader[bus.rawValue]
                SettingsRow(label: model.busLabel(SendBus(rawValue: bus.rawValue)!), labelColor: bus.color) {
                    HStack(spacing: 4) {
                        SettingsChip(text: "POST", active: !pre, color: bus.color) { model.setSendPreFader(SendBus(rawValue: bus.rawValue)!, false) }
                        SettingsChip(text: "PRE", active: pre, color: bus.color) { model.setSendPreFader(SendBus(rawValue: bus.rawValue)!, true) }
                    }
                }
            }
            SettingsNote("POST: the send follows the strip's fader and mute. PRE: the send is taken before them, so a cut strip keeps feeding the effect.")
        }
    }

    // MARK: Recording

    private var recording: some View {
        SettingsSection(title: "RECORDING") {
            SettingsRow(label: "FOLDER") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.recordingsFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        SettingsChip(text: "CHOOSE…", active: false) { model.chooseRecordingsFolder() }
                        if model.recordingsFolder != AppModel.defaultRecordingsFolder {
                            SettingsChip(text: "DEFAULT", active: false) { model.resetRecordingsFolder() }
                        }
                    }
                }
            }
            SettingsNote("Master recordings: 24-bit WAV of what you hear, after the limiter (⌘R).")
        }
    }

    // MARK: Plugins

    private var plugins: some View {
        SettingsSection(title: "PLUGINS") {
            SettingsRow(label: "AUDIO UNITS") {
                HStack(spacing: 10) {
                    Text("\(model.installedPlugins.count) effects installed")
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Theme.text)
                    SettingsChip(text: "RESCAN", active: false) { model.rescanPlugins() }
                }
            }
            SettingsNote("Set a plugin 100 % wet: each bus is a send, the dry signal already goes to the master.")
        }
    }

    // MARK: Stem separation (PRD § 12.2)

    private var separation: some View {
        SettingsSection(title: "STEM SEPARATION") {
            SettingsRow(label: "ENGINE") {
                HStack(spacing: 10) {
                    Text(engineStatus)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(model.modelStatus == .ready ? Theme.reverb : Theme.text)
                    if case .downloading = model.separation {
                        SettingsChip(text: "CANCEL", active: false) { model.cancelSeparation() }
                    } else if model.modelStatus != .ready {
                        SettingsChip(text: "DOWNLOAD \(Int(Double(ModelCatalog.totalBytes) / 1e6)) MB", active: false) { model.startDownload() }
                    }
                    if model.modelStatus != .missing, !model.separation.isActive {
                        SettingsChip(text: "DELETE", active: false) { model.deleteModels() }
                    }
                }
            }
            SettingsRow(label: "STEMS") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.stemsFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        SettingsChip(text: "CHOOSE…", active: false) { model.chooseStemsFolder() }
                        if model.stemsFolder != AppModel.defaultStemsFolder {
                            SettingsChip(text: "DEFAULT", active: false) { model.resetStemsFolder() }
                        }
                    }
                }
            }
            SettingsNote(ModelCatalog.licenseNotice)
        }
    }

    private var engineStatus: String {
        if case let .downloading(received, total) = model.separation { return "downloading… \(received / 1_000_000) / \(total / 1_000_000) MB" }
        switch model.modelStatus {
        case .ready: return "\(ModelCatalog.name) ready (\(ModelCatalog.shortRevision))"
        case .missing: return "not downloaded"
        case let .partial(ready): return "\(ready) of 4 files, incomplete"
        }
    }
}

// MARK: - Building blocks

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Fonts.label(12, weight: 850))
                .tracking(1.4)
                .foregroundStyle(Theme.text)
            content
        }
    }
}

private struct SettingsRow<Content: View>: View {
    var label: String
    var labelColor: Color = Theme.textDim
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(Fonts.label(10.5, weight: 800))
                .tracking(1)
                .foregroundStyle(labelColor)
                .frame(width: 92, alignment: .trailing)
                .padding(.top, 4)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsNote: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Fonts.mono(9.5))
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 104)
    }
}

private struct SettingsChip: View {
    var text: String
    var active: Bool
    var color: Color = Theme.text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Fonts.mono(10, weight: 700))
                .foregroundStyle(active ? Theme.bg : Theme.textDim)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(minWidth: 34, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? color : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? color : Theme.border, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
