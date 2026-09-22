import AppKit
import DubStemMixCore
import SwiftUI

//   swift run DubStemMix ["<dossier, projet .dubstem ou setlist .dubset>"]   lance l'app et l'ouvre
//   swift run DubStemMix --detect-tempo "<dossier>" [texte à exclure]   estime le BPM d'un dossier de stems
//   swift run DubStemMix --check-plugins [--all]         charge chaque plugin AU tiers (ou tous) installé, sans son, et rapporte
//   swift run DubStemMix --check-documents               auto-contrôle projets + setlist, sans interface ni son
//   swift run DubStemMix --check-audio                   carte son, buffer, charge DSP et décrochages sur le vrai moteur
//   swift run DubStemMix --check-plugin-crash            tue le processus d'un plugin hors processus et vérifie la bascule
//   swift run DubStemMix --download-models               télécharge les 4 réseaux htdemucs_ft (663 Mo) dans le dossier de l'app
//   swift run DubStemMix --split <fichier> [--out dir] [--provider cpu|coreml-…]   sépare un morceau avec les vrais modèles et rapporte Σ stems vs mix
//   swift run DubStemMix --snapshot out.png [--fx | --master | --inserts | --settings]   rend l'interface (données de démo) dans un PNG

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
        } else if args.contains("--check-plugin-crash") {
            PluginCrashCheck.run()
        } else if args.contains("--download-models") {
            SplitCheck.downloadModels()
        } else if let i = args.firstIndex(of: "--split"), i + 1 < args.count {
            let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let provider = args.firstIndex(of: "--provider").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let threads = args.firstIndex(of: "--threads").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            SplitCheck.split(args[i + 1], out: out, provider: provider, threads: threads)
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let page: MixController.Page = args.contains("--fx") ? .fx : args.contains("--master") ? .master : args.contains("--inserts") ? .inserts : .mix
            snapshot(to: args[i + 1], page: page, settings: args.contains("--settings"))
        } else {
            DubStemMixApp.main()
        }
    }

    @MainActor
    private static func snapshot(to path: String, page: MixController.Page, settings: Bool) {
        guard let model = try? AppModel(preview: true) else {
            print("Échec de la création du modèle de démonstration")
            exit(1)
        }
        model.mix.setPage(page)
        let renderer = settings
            ? ImageRenderer(content: AnyView(SettingsView(model: model)))
            : ImageRenderer(content: AnyView(RootView(model: model).frame(width: 1440, height: 900)))
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
        Settings {
            if let model { SettingsView(model: model) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model?.newSession() }.keyboardShortcut("n")
                Button("Open…") { model?.chooseFilesToOpen() }.keyboardShortcut("o")
                Button("Split a Song…") { model?.chooseSongToSplit() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model?.saveProject() }.keyboardShortcut("s")
                Button("Save Project As…") { model?.saveProject(askLocation: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Add Song to Setlist") { model?.addCurrentProjectToSetlist() }
                Button("Next Song") { model?.openNextInSetlist() }
                Button("Previous Song") { model?.openNextInSetlist(offset: -1) }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to DubStemMix") { model?.showWelcome = true }
                Button("DubStemMix on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/yoanbernabeu/dubstemmix")!) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel? {
        didSet { MainActor.assumeIsolated { openPending() } }
    }
    /// Documents double-clicked in the Finder before the window (and the model) exist.
    @MainActor private var pendingURLs: [URL] = []

    /// Projects, setlists and stems opened from the Finder (the app owns .dubstem and .dubset).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            pendingURLs += urls
            openPending()
        }
    }

    @MainActor private func openPending() {
        guard let model, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        model.open(urls)
    }

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
