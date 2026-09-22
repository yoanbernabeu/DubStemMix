// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DubStemMix",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Stem separation (PRD § 12): ONNX Runtime, Microsoft's official SwiftPM package (MIT).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.19.2"),
    ],
    targets: [
        // Noyaux DSP temps réel des effets intégrés (C : ni allocation ni verrou sur le thread audio).
        .target(name: "DubDSP"),
        // Moteur audio, MIDImix et logique de mix — sans interface, testable.
        .target(name: "DubStemMixCore", dependencies: ["DubDSP"]),
        .testTarget(name: "DubStemMixCoreTests", dependencies: ["DubStemMixCore"]),
        // Stem separation with htdemucs_ft (PRD § 12): decoding, overlap-add, ONNX inference, model download.
        .target(
            name: "StemSplit",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
        ),
        .testTarget(name: "StemSplitTests", dependencies: ["StemSplit"]),
        // L'app SwiftUI.
        .executableTarget(
            name: "DubStemMix",
            dependencies: ["DubStemMixCore", "StemSplit"],
            resources: [.process("Resources")]
        ),
    ]
)
