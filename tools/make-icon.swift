// Draws the DubStemMix app icon from the PRD § 5.11 palette and writes an .iconset + .icns.
//
//   swift tools/make-icon.swift Design
//
// Concept: one big console knob whose arc is split in the three bus colours (delay ochre, reverb sage,
// bus 3 brick), cream pointer, on the near-black stage background. Flat: no gradient, no shadow.

import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Design")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let bg = color(0x14110F), surface = color(0x1E1A17), border = color(0x2E2823), cream = color(0xEDE3CF)
let ochre = color(0xD9A441), sage = color(0x7E9B5A), brick = color(0xC2553A)

/// Draws the icon on a `size`-wide canvas (all measures scale from 1024).
func draw(size: CGFloat, in context: CGContext) {
    let s = size / 1024
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // macOS icon grid: a rounded square of 824 pt on the 1024 canvas.
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    context.addPath(CGPath(roundedRect: plate, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil))
    context.setFillColor(bg)
    context.fillPath()

    let center = CGPoint(x: 512 * s, y: 512 * s)
    let radius = 262 * s
    let width = 96 * s
    // A knob arc runs 270°, from 7:30 (bottom left) clockwise to 4:30. CoreGraphics angles: 0 = right,
    // counter-clockwise positive; the visual sweep goes clockwise, so angles decrease.
    let start = CGFloat(225).radians, end = CGFloat(-45).radians

    // Track
    context.setLineCap(.round)
    context.setLineWidth(width)
    context.setStrokeColor(border)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    context.strokePath()

    // Three bus segments with a small gap between them.
    let gap = CGFloat(7).radians
    let sweep = (start - end) / 3
    for (i, fill) in [ochre, sage, brick].enumerated() {
        let a0 = start - sweep * CGFloat(i) - (i == 0 ? 0 : gap / 2)
        let a1 = start - sweep * CGFloat(i + 1) + (i == 2 ? 0 : gap / 2)
        context.setLineCap(.butt)
        context.setStrokeColor(fill)
        context.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        context.strokePath()
    }
    // Round the two outer ends.
    context.setLineCap(.round)
    for (angle, fill) in [(start, ochre), (end, brick)] {
        context.setStrokeColor(fill)
        context.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + (angle == start ? -0.001 : 0.001), clockwise: angle == start)
        context.strokePath()
    }

    // Knob body
    let body = 158 * s
    context.setFillColor(surface)
    context.fillEllipse(in: CGRect(x: center.x - body, y: center.y - body, width: body * 2, height: body * 2))
    context.setStrokeColor(border)
    context.setLineWidth(10 * s)
    context.strokeEllipse(in: CGRect(x: center.x - body, y: center.y - body, width: body * 2, height: body * 2))

    // Pointer: a cream capsule at 72 % of the travel, like a send knob opened on the throw.
    let position: CGFloat = 0.72
    let angle = start - (start - end) * position
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle)
    let capsule = CGRect(x: body * 0.22, y: -30 * s, width: body * 0.72, height: 60 * s)
    context.addPath(CGPath(roundedRect: capsule, cornerWidth: 30 * s, cornerHeight: 30 * s, transform: nil))
    context.setFillColor(cream)
    context.fillPath()
    context.restoreGState()
}

extension CGFloat {
    var radians: CGFloat { self * .pi / 180 }
}

func render(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(size: CGFloat(size), in: context)
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = output.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: output.appending(path: "AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Icon written to \(output.path)" : "iconutil failed")
