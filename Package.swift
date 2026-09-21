// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DubStemMix",
    platforms: [.macOS(.v26)],
    targets: [
        // Noyaux DSP temps réel des effets intégrés (C : ni allocation ni verrou sur le thread audio).
        .target(name: "DubDSP"),
        // Moteur audio, MIDImix et logique de mix — sans interface, testable.
        .target(name: "DubStemMixCore", dependencies: ["DubDSP"]),
        .testTarget(name: "DubStemMixCoreTests", dependencies: ["DubStemMixCore"]),
        // L'app SwiftUI.
        .executableTarget(
            name: "DubStemMix",
            dependencies: ["DubStemMixCore"],
            resources: [.process("Resources")]
        ),
        // Jalon M0 : spike technique jetable, conservé jusqu'à la validation du M1.
        .executableTarget(
            name: "M0Spike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
