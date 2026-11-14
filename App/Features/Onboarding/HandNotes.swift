import AppKit
import SwiftUI

/// The red ink of the hand-written notes, the same as on the README images.
enum HandInk {
    static let color = Color(red: 0.898, green: 0.282, blue: 0.302)

    /// Bradley Hand ships with macOS; Noteworthy stands in if it is missing.
    static func font(size: CGFloat) -> Font {
        let name = NSFont(name: "BradleyHandITCTT-Bold", size: size) != nil ? "BradleyHandITCTT-Bold" : "Noteworthy-Bold"
        return .custom(name, fixedSize: size)
    }
}

/// A short hand-written note, tilted a little.
struct HandNote: View {
    let text: LocalizedStringKey
    var size: CGFloat = 20
    var rotation: Double = -3
    var alignment = TextAlignment.leading

    var body: some View {
        Text(text)
            .font(HandInk.font(size: size))
            .foregroundStyle(HandInk.color)
            .multilineTextAlignment(alignment)
            .lineSpacing(-size * 0.12)
            .fixedSize()
            .rotationEffect(.degrees(rotation))
    }
}

/// A hand-drawn arrow: one curve from `start` to `end`, bent toward `control`, with an open head at the end. The
/// points are fractions of the shape's frame. Custom because no system shape draws a curved arrow.
struct HandArrow: Shape {
    let start: UnitPoint
    let control: UnitPoint
    let end: UnitPoint
    var head: CGFloat = 11

    func path(in rect: CGRect) -> Path {
        func point(_ unit: UnitPoint) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        }
        let from = point(start), bend = point(control), to = point(end)
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: bend)
        // The head opens back along the direction the curve arrives from.
        let angle = atan2(to.y - bend.y, to.x - bend.x)
        for side in [-1.0, 1.0] {
            let wing = angle + .pi + side * 0.5
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + cos(wing) * head, y: to.y + sin(wing) * head))
        }
        return path
    }
}

extension HandArrow {
    /// The arrow in ink, drawn on from its tail when `isShown` turns true.
    func inked(isShown: Bool, lineWidth: CGFloat = 2.4) -> some View {
        trim(from: 0, to: isShown ? 1 : 0)
            .stroke(HandInk.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}
