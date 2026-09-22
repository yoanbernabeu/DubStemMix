import AppKit
import SwiftUI

/// First-launch welcome (PRD § 9, M5): the three things to know before the first note. Help ▸ Welcome reopens it.
struct WelcomeView: View {
    var model: AppModel
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(Text("DUB").foregroundStyle(Theme.delay))\(Text("STEM").foregroundStyle(Theme.reverb))\(Text("MIX").foregroundStyle(Theme.bus3))")
                .font(Fonts.label(28, weight: 900, width: 122))
            Text("A dub mixing console for the Akai MIDImix. Stems in, dub out.")
                .font(Fonts.label(13, weight: 700))
                .foregroundStyle(Theme.text)

            step(1, "Plug in the MIDImix, on its factory mapping.",
                 "If you ever changed it with the Akai MIDImix Editor: File ▸ New, then Send to Hardware. The status line at the bottom left says “connected”.")
            step(2, "Press SEND ALL on the console.",
                 "The app then knows where every knob and fader is. Knobs are not motorized: after a page change, a knob acts once it reaches the value it now drives (the cream ghost mark).")
            step(3, "Drop a folder of stems anywhere, then drag each stem onto a strip.",
                 "Or drop a full song in SPLIT A SONG: drums, bass, instruments and vocals land on strips 1–4. The separation engine (663 MB) is downloaded once, after asking you.")
            step(4, "Play.",
                 "Space plays. BANK RIGHT cycles the knob pages MIX → FX → MASTER → INSERTS, BANK LEFT comes back to MIX. REC ARM held is the dub throw. Keys: D drop, H hold, C crash, R rewind, ⌘R record, ⌘, settings.")

            HStack {
                Button { NSWorkspace.shared.open(URL(string: "https://github.com/yoanbernabeu/DubStemMix")!) } label: {
                    Text("README on GitHub").font(Fonts.mono(10.5)).foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: dismiss) {
                    Text("LET'S GO")
                        .font(Fonts.label(12, weight: 850))
                        .tracking(1)
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 560)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Fonts.mono(13, weight: 700))
                .foregroundStyle(Theme.bg)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.delay))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.label(12.5, weight: 800)).foregroundStyle(Theme.text)
                Text(detail).font(Fonts.mono(10.5)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
