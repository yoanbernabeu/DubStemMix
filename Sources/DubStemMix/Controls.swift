import SwiftUI

// Contrôles de base : potard, fader, vu-mètre, boutons de tranche.

private struct KnobArc: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(135 + 270 * from),
            endAngle: .degrees(135 + 270 * to),
            clockwise: false
        )
        return path
    }
}

struct Knob: View {
    @Binding var value: Double
    var color: Color
    var ghost: Double? = nil
    var size: CGFloat = 68

    @State private var dragStart: Double?

    var body: some View {
        let line = size * 0.14
        ZStack {
            KnobArc(from: 0, to: 1)
                .stroke(Theme.border, style: StrokeStyle(lineWidth: line, lineCap: .round))
            if value > 0.005 {
                KnobArc(from: 0, to: value)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().stroke(Theme.border, lineWidth: 1.5))
                .padding(size * 0.2)
            Capsule()
                .fill(value > 0.005 ? color : Theme.textDim)
                .frame(width: size * 0.07, height: size * 0.2)
                .offset(y: -size * 0.17)
                .rotationEffect(.degrees(-135 + 270 * value))
            if let ghost {
                Circle()
                    .fill(Theme.text)
                    .frame(width: line * 0.85, height: line * 0.85)
                    .offset(y: -(size - line) / 2)
                    .rotationEffect(.degrees(-135 + 270 * ghost))
            }
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    value = min(1, max(0, start - drag.translation.height / 160))
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

struct Meter: View {
    var level: Double
    private let segments = 22

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Double(segments - 1 - index) / Double(segments)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? color(for: threshold) : Theme.border.opacity(0.6))
            }
        }
        .frame(width: 7)
    }

    private func color(for threshold: Double) -> Color {
        if threshold >= 0.9 { return Theme.rec }
        if threshold >= 0.72 { return Theme.delay }
        return Theme.reverb
    }
}

struct Fader: View {
    @Binding var value: Double
    var ghost: Double? = nil

    var body: some View {
            GeometryReader { geo in
                let capHeight: CGFloat = 26
                let travel = geo.size.height - capHeight
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.border)
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                    // Repère de gain unité
                    Rectangle()
                        .fill(Theme.textDim)
                        .frame(width: 26, height: 1.5)
                        .offset(y: capHeight / 2 + travel * (1 - 0.8))
                    if let ghost {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 36, height: capHeight)
                            .offset(y: travel * (1 - ghost))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.text)
                        .frame(width: 36, height: capHeight)
                        .overlay(Rectangle().fill(Theme.bg).frame(height: 2))
                        .offset(y: travel * (1 - value))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        value = min(1, max(0, 1 - (drag.location.y - capHeight / 2) / travel))
                    }
                )
            }
            .frame(width: 40)
    }
}

/// Habillage commun des boutons de tranche : plein (inversé) quand actif, contour sinon.
private struct StripButtonLabel: View {
    var title: String
    var active: Bool
    var activeColor: Color

    var body: some View {
        Text(title)
            .font(Fonts.label(12, weight: 800))
            .tracking(1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(active ? Theme.bg : Theme.textDim)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 4).fill(active ? activeColor : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? activeColor : Theme.border, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

struct StripButton: View {
    var title: String
    var active: Bool
    var activeColor: Color = Theme.text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            StripButtonLabel(title: title, active: active, activeColor: activeColor)
        }
        .buttonStyle(.plain)
    }
}

/// Bouton momentané (dub throw) : actif tant qu'on le maintient.
struct MomentaryButton: View {
    var title: String
    var active: Bool
    var activeColor: Color = Theme.text
    var onChange: (Bool) -> Void

    @State private var pressed = false

    var body: some View {
        StripButtonLabel(title: title, active: active, activeColor: activeColor)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onChange(true)
                    }
                    .onEnded { _ in
                        pressed = false
                        onChange(false)
                    }
            )
    }
}
