import SwiftUI
import CoreText

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum Theme {
    static let bg = Color(hex: 0x14110F)
    static let surface = Color(hex: 0x1E1A17)
    static let border = Color(hex: 0x2E2823)
    static let text = Color(hex: 0xEDE3CF)
    static let textDim = Color(hex: 0x9A8F7E)
    static let delay = Color(hex: 0xD9A441)
    static let reverb = Color(hex: 0x7E9B5A)
    static let bus3 = Color(hex: 0xC2553A)
    static let rec = Color(hex: 0xE5412D)
}

enum Bus: Int, CaseIterable {
    case delay, reverb, bus3

    var color: Color {
        switch self {
        case .delay: Theme.delay
        case .reverb: Theme.reverb
        case .bus3: Theme.bus3
        }
    }

    var label: String {
        switch self {
        case .delay: "DELAY"
        case .reverb: "REVERB"
        case .bus3: "PHASER"
        }
    }
}

/// Polices embarquées (variables) : Archivo pour les libellés, JetBrains Mono pour les valeurs.
@MainActor
enum Fonts {
    private static var cache: [String: Font] = [:]

    /// The fonts live in the package's resource bundle, whose layout depends on the toolchain that built it
    /// (flat, or Contents/Resources). They are looked up by file name, never through `Bundle.module`,
    /// which traps when it cannot load the bundle. Missing fonts fall back to the system ones.
    static func register() {
        let names = ["Archivo-Variable.ttf", "JetBrainsMono-Variable.ttf"]
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
            .map { $0.appending(path: "DubStemMix_DubStemMix.bundle") }
        for name in names {
            guard let url = roots.lazy.compactMap({ find(name, under: $0) }).first else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func find(_ fileName: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == fileName { return url }
        return nil
    }

    static func label(_ size: CGFloat, weight: Double = 750, width: Double = 112) -> Font {
        variable(family: "Archivo", size: size, axes: ["wght": weight, "wdth": width])
    }

    static func mono(_ size: CGFloat, weight: Double = 500) -> Font {
        variable(family: "JetBrains Mono", size: size, axes: ["wght": weight])
    }

    private static func variable(family: String, size: CGFloat, axes: [String: Double]) -> Font {
        let key = "\(family)-\(size)-\(axes.sorted { $0.key < $1.key })"
        if let font = cache[key] { return font }
        var variations: [NSNumber: NSNumber] = [:]
        for (axis, value) in axes {
            let tag = axis.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            variations[NSNumber(value: tag)] = NSNumber(value: value)
        }
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: variations,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        cache[key] = font
        return font
    }
}
