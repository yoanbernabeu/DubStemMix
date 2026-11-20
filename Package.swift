// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DubStemMix",
    platforms: [.macOS(.v15)],
    targets: [
        // Noyaux DSP temps réel des effets intégrés (C : ni allocation ni verrou sur le thread audio).
        .target(name: "DubDSP"),
        // MP3 encoder for exported sessions (PRD § 5.9): libmp3lame 3.100, unmodified, LGPL 2 (see Sources/LAME/COPYING).
        .target(
            name: "LAME",
            exclude: ["COPYING"],
            cSettings: [
                .define("STDC_HEADERS"), .define("HAVE_STDINT_H"), .define("HAVE_ERRNO_H"), .define("HAVE_FCNTL_H"),
                .define("HAVE_LIMITS_H"), .define("ieee754_float32_t", to: "float"), .headerSearchPath("."),
                .unsafeFlags(["-w"]), // third-party code, left as is
            ]
        ),
        // Moteur audio, MIDImix et logique de mix — sans interface, testable.
        .target(name: "DubStemMixCore", dependencies: ["DubDSP", "LAME"]),
        .testTarget(name: "DubStemMixCoreTests", dependencies: ["DubStemMixCore"]),
        // Stem separation with htdemucs_ft (PRD § 12): decoding, overlap-add, ONNX inference, model download.
        .target(name: "StemSplit", dependencies: ["OnnxRuntimeBindings"]),
        // ONNX Runtime 1.24.2 (MIT, Microsoft). Its Objective-C bindings are a copy of Microsoft's Swift package,
        // kept in the repository since that package left GitHub (see Sources/OnnxRuntimeBindings/README.md); the
        // library itself is Microsoft's own archive, the one that package pointed to.
        .target(
            name: "OnnxRuntimeBindings",
            dependencies: ["onnxruntime"],
            exclude: ["LICENSE", "README.md"],
            cxxSettings: [.define("SPM_BUILD"), .unsafeFlags(["-w"])] // third-party code, left as is
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
        ),
        .testTarget(name: "StemSplitTests", dependencies: ["StemSplit"]),
        // L'app SwiftUI.
        .executableTarget(
            name: "DubStemMix",
            dependencies: ["DubStemMixCore", "StemSplit"],
            resources: [.process("Resources")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
