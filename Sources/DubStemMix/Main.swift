import AppKit
import DubStemMixCore
import SwiftUI

//   swift run DubStemMix ["<dossier, projet .dubstem ou setlist .dubset>"]   lance l'app et l'ouvre
//   swift run DubStemMix --detect-tempo "<dossier>" [texte à exclure]   estime le BPM d'un dossier de stems
//   swift run DubStemMix --check-plugins                 charge chaque plugin AU tiers installé, sans son, et rapporte
//   swift run DubStemMix --check-documents               auto-contrôle projets + setlist, sans interface ni son
//   swift run DubStemMix --check-audio                   carte son, buffer, charge DSP et décrochages sur le vrai moteur
//   swift run DubStemMix --snapshot out.png [--fx]       rend l'interface (données de démo) dans un PNG

@main
enum Main {
    @MainActor
    static func main() {
        Fonts.register()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--detect-tempo"), i + 1 < args.count {
            let files = StemImporter.audioFiles(in: [URL(fileURLWithPath: args[i + 1])])
            let exclude = args.dropFirst(i + 2).first
            let kept = files.filter { file in exclude.map { !file.lastPathComponent.contains($0) } ?? true }
            print(TempoDetector.estimate(urls: kept).map { "\($0) BPM (\(kept.count) fichiers)" } ?? "tempo introuvable")
        } else if args.contains("--check-plugins") {
            PluginCheck.run()
        } else if args.contains("--check-documents") {
            DocumentsCheck.run()
        } else if args.contains("--check-audio") {
            AudioCheck.run()
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], fxPage: args.contains("--fx"))
        } else {
            DubStemMixApp.main()
        }
    }

    @MainActor
    private static func snapshot(to path: String, fxPage: Bool) {
        guard let model = try? AppModel(preview: true) else {
            print("Échec de la création du modèle de démonstration")
            exit(1)
        }
        if fxPage { model.mix.setPage(.fx) }
        let renderer = ImageRenderer(content: RootView(model: model).frame(width: 1440, height: 900))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            print("Échec du rendu")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Interface rendue dans \(path)")
    }
}

struct DubStemMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = try? AppModel()

    var body: some Scene {
        WindowGroup("DubStemMix") {
            if let model {
                RootView(model: model)
                    .frame(minWidth: 1280, minHeight: 820)
                    .onAppear {
                        delegate.model = model
                        // Dossiers ou fichiers passés en argument au lancement.
                        let paths = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
                        if !paths.isEmpty, model.title.isEmpty {
                            model.open(paths.map { URL(fileURLWithPath: $0) })
                        }
                    }
            } else {
                Text("The audio engine could not start.")
                    .padding(40)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model?.newSession() }.keyboardShortcut("n")
                Button("Open…") { model?.chooseFilesToOpen() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model?.saveProject() }.keyboardShortcut("s")
                Button("Save Project As…") { model?.saveProject(askLocation: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Add Song to Setlist") { model?.addCurrentProjectToSetlist() }
                Button("Next Song") { model?.openNextInSetlist() }
                Button("Previous Song") { model?.openNextInSetlist(offset: -1) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lancée via `swift run` (sans bundle), l'app doit demander elle-même à passer au premier plan.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutDown() } // éteint les LEDs de la console
    }
}
