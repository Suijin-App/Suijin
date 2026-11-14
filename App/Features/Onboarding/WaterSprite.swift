import SwiftUI

/// The Suijin water sprite: a pixel droplet on a 12×14 grid with a curled tip, two eyes and two small boots. One
/// colour per kind of session, as in the promo film. Pure value: a pose in, the coloured cells out.
struct WaterSprite: Equatable {
    enum Tint: String, CaseIterable {
        /// Any other agent, Claude Code, Codex, a shell.
        case aqua, claude, codex, shell
    }
    enum Eyes { case open, happy, blink, wide, left, right, up, down }
    enum Arms { case down, up, wave }
    enum Legs { case stand, tuck, sit, swingLeft, swingRight }
    enum Mouth { case none, smile, open }
    enum Part { case body, shade, highlight, eye, blush }

    struct Cell: Hashable {
        let column: Int
        let row: Int
    }

    static let columns = 12
    static let rows = 14

    var tint: Tint
    var eyes = Eyes.open
    var arms = Arms.down
    var legs = Legs.stand
    var mouth = Mouth.none
    var blush = false

    /// Body rows 0…11 as first and last column; the tip curls to the right.
    private static let body = [(6, 6), (5, 6), (5, 6), (4, 7), (3, 8), (2, 9), (1, 10), (1, 10), (1, 10), (1, 10), (2, 9), (3, 8)]

    /// Every filled cell of the pose. Later parts are drawn over earlier ones: body, arms, legs, cheeks, mouth, eyes.
    var cells: [Cell: Part] {
        var cells: [Cell: Part] = [:]
        func put(_ points: [(Int, Int)], _ part: Part) {
            for (column, row) in points { cells[Cell(column: column, row: row)] = part }
        }
        for (row, span) in Self.body.enumerated() {
            for column in span.0...span.1 { cells[Cell(column: column, row: row)] = row == 11 ? .shade : .body }
        }
        // The shade turns the corner (light comes from the upper left), and one pixel catches the light.
        put([(9, 10), (10, 9)], .shade)
        put([(3, 5)], .highlight)
        switch arms {
        case .down: break
        case .up: put([(0, 7), (0, 6), (0, 5), (11, 7), (11, 6), (11, 5)], .body)
        case .wave: put([(11, 7), (11, 6), (11, 5)], .body)
        }
        switch legs {
        case .stand:
            put([(4, 12), (7, 12)], .body)
            put([(3, 13), (4, 13), (7, 13), (8, 13)], .shade)
        case .tuck: put([(3, 12), (4, 12), (7, 12), (8, 12)], .body)
        case .sit:
            put([(4, 12), (7, 12)], .body)
            put([(4, 13), (7, 13)], .shade)
        case .swingLeft:
            // Sitting, the left boot kicked outward.
            put([(4, 12), (7, 12)], .body)
            put([(3, 13), (7, 13)], .shade)
        case .swingRight:
            put([(4, 12), (7, 12)], .body)
            put([(4, 13), (8, 13)], .shade)
        }
        if blush { put([(2, 9), (9, 9)], .blush) }
        switch mouth {
        case .none: break
        case .smile: put([(4, 9), (7, 9), (5, 10), (6, 10)], .eye)
        case .open: put([(5, 9), (6, 9), (5, 10), (6, 10)], .eye)
        }
        switch eyes {
        case .open: put([(3, 7), (3, 8), (8, 7), (8, 8)], .eye)
        case .happy: put([(2, 8), (3, 7), (4, 8), (7, 8), (8, 7), (9, 8)], .eye)
        case .blink: put([(3, 8), (8, 8)], .eye)
        case .wide: put([(3, 6), (3, 7), (3, 8), (8, 6), (8, 7), (8, 8)], .eye)
        case .left: put([(2, 7), (2, 8), (7, 7), (7, 8)], .eye)
        case .right: put([(4, 7), (4, 8), (9, 7), (9, 8)], .eye)
        case .up: put([(3, 6), (3, 7), (8, 6), (8, 7)], .eye)
        case .down: put([(3, 8), (3, 9), (8, 8), (8, 9)], .eye)
        }
        return cells
    }
}

extension WaterSprite.Tint {
    /// The colour of a part. None is the interface's accent blue, and each body stays visible on light and dark.
    func color(_ part: WaterSprite.Part) -> Color {
        let hex: UInt32 = switch (self, part) {
        case (.aqua, .body): 0x19B8D8
        case (.aqua, .shade): 0x0F8FB5
        case (.aqua, .highlight): 0xDDF8FF
        case (.aqua, .eye): 0x0A2B40
        case (.aqua, .blush): 0xF7A8CC
        case (.claude, .body): 0xEE7B5C
        case (.claude, .shade): 0xC9583D
        case (.claude, .highlight): 0xFFE7DD
        case (.claude, .eye): 0x3D1A10
        case (.claude, .blush): 0xFFC0CB
        case (.codex, .body): 0x7A6BF2
        case (.codex, .shade): 0x584AC9
        case (.codex, .highlight): 0xE8E4FF
        case (.codex, .eye): 0x17113F
        case (.codex, .blush): 0xE9A6F2
        case (.shell, .body): 0x22B585
        case (.shell, .shade): 0x168A66
        case (.shell, .highlight): 0xDBFAEE
        case (.shell, .eye): 0x062F25
        case (.shell, .blush): 0xF8BDB8
        }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A sprite drawn with square pixels of `pixel` points. Custom drawing because the mascot is pixel art that no
/// system symbol or image provides; it is decoration, hidden from VoiceOver.
struct WaterSpriteView: View {
    let sprite: WaterSprite
    var pixel: CGFloat = 6

    var body: some View {
        Canvas { context, _ in
            for (cell, part) in sprite.cells {
                // A hair wider than a pixel, so neighbours leave no seam at fractional sizes.
                let rect = CGRect(x: CGFloat(cell.column) * pixel, y: CGFloat(cell.row) * pixel,
                                  width: pixel + 0.35, height: pixel + 0.35)
                context.fill(Path(rect), with: .color(sprite.tint.color(part)))
            }
        }
        .frame(width: CGFloat(WaterSprite.columns) * pixel, height: CGFloat(WaterSprite.rows) * pixel)
        .accessibilityHidden(true)
    }
}

/// Where the pointer is over the welcome tour, in the tour's coordinate space; the sprites look at it.
private struct TourPointerKey: EnvironmentKey {
    static let defaultValue: CGPoint? = nil
}

extension EnvironmentValues {
    var tourPointer: CGPoint? {
        get { self[TourPointerKey.self] }
        set { self[TourPointerKey.self] = newValue }
    }
}

/// The name of the tour's coordinate space, which pointer positions and sprite frames share.
let tourCoordinateSpace = "onboardingTour"

/// A sprite that lives a little: it blinks, follows the pointer with its eyes, and hops now and then (idle), keeps
/// jumping with happy eyes (cheering) or sits swinging its legs (sitting). A click makes it jump for joy with a heart
/// above it. With Reduce Motion it holds one still pose and only its face answers.
struct LivelySprite: View {
    enum Mood { case idle, cheering, sitting }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tourPointer) private var pointer
    let tint: WaterSprite.Tint
    var pixel: CGFloat = 6
    var mood = Mood.idle
    /// Seconds this sprite runs ahead of the others, so a row of them does not move in step.
    var phase: Double = 0

    @State private var frame = CGRect.zero
    @State private var tappedAt: Date?

    /// How long the answer to a click lasts.
    static let joy = 0.9

    var body: some View {
        Group {
            if reduceMotion {
                // No timeline: the happy face shows until the click's time is cleared.
                drawing(at: nil, sinceTap: tappedAt == nil ? nil : 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    drawing(at: timeline.date.timeIntervalSinceReferenceDate + phase,
                            sinceTap: tappedAt.map { timeline.date.timeIntervalSince($0) })
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(tourCoordinateSpace)) } action: { frame = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date.now
            tappedAt = now
            Task {
                try? await Task.sleep(for: .seconds(Self.joy))
                if tappedAt == now { tappedAt = nil }
            }
        }
    }

    private func drawing(at time: Double?, sinceTap: Double?) -> some View {
        let gaze = LivelySprite.gaze(from: CGPoint(x: frame.midX, y: frame.midY), to: pointer, reach: pixel * 8)
        let pose = LivelySprite.pose(tint: tint, mood: mood, time: time, gaze: gaze, sinceTap: sinceTap)
        return WaterSpriteView(sprite: pose.sprite, pixel: pixel)
            .offset(y: -pose.lift * pixel)
            .overlay(alignment: .top) {
                if let sinceTap, sinceTap < Self.joy {
                    PixelHeart(pixel: pixel * 0.6)
                        .offset(y: -pixel * (5 + (reduceMotion ? 0 : sinceTap * 9)) - pose.lift * pixel)
                        .opacity(1 - sinceTap / Self.joy)
                }
            }
    }

    /// Where the eyes go for a pointer at `pointer`: nil without one, happy when it is on the sprite, else the side
    /// it is on.
    static func gaze(from center: CGPoint, to pointer: CGPoint?, reach: CGFloat) -> WaterSprite.Eyes? {
        guard let pointer else { return nil }
        let dx = pointer.x - center.x, dy = pointer.y - center.y
        if hypot(dx, dy) < reach { return .happy }
        if abs(dx) > abs(dy) * 0.8 { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
    }

    /// The sprite and how many pixels it is off the ground at `time` (nil is the still pose), looking where `gaze`
    /// says, `sinceTap` seconds after a click.
    static func pose(tint: WaterSprite.Tint, mood: Mood, time: Double?, gaze: WaterSprite.Eyes? = nil,
                     sinceTap: Double? = nil) -> (sprite: WaterSprite, lift: Double) {
        var sprite = WaterSprite(tint: tint)
        var lift = 0.0
        let blinking = time.map { $0.truncatingRemainder(dividingBy: 3.4) < 0.14 } ?? false
        let resting: WaterSprite.Eyes = blinking ? .blink : (gaze ?? .open)
        switch mood {
        case .idle:
            sprite.eyes = resting
            if let time {
                // One short hop every four seconds.
                let hop = time.truncatingRemainder(dividingBy: 4) / 0.45
                if hop < 1 {
                    lift = sin(hop * .pi) * 2.5
                    sprite.legs = .tuck
                }
            }
        case .cheering:
            sprite.eyes = .happy
            sprite.blush = true
            if let time {
                lift = abs(sin(time * .pi / 0.9)) * 3.5
                if lift > 0.8 { sprite.legs = .tuck }
            }
        case .sitting:
            sprite.legs = .sit
            sprite.eyes = resting
            if let time {
                // The legs swing, one after the other, with a rest between.
                let swing = time.truncatingRemainder(dividingBy: 2.4)
                if swing < 0.5 { sprite.legs = .swingLeft } else if swing > 1.2, swing < 1.7 { sprite.legs = .swingRight }
            }
        }
        if let sinceTap, sinceTap < joy {
            // A click: a jump for joy, whatever it was doing.
            sprite.eyes = .happy
            sprite.blush = true
            sprite.mouth = .open
            if time != nil {
                lift = max(lift, sin(sinceTap / joy * .pi) * 4)
                sprite.legs = .tuck
            }
        }
        return (sprite, lift)
    }
}

/// A small pixel heart, the sprite's answer to a click.
private struct PixelHeart: View {
    let pixel: CGFloat
    private static let rows = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]

    var body: some View {
        Canvas { context, _ in
            for (row, line) in Self.rows.enumerated() {
                for (column, mark) in line.enumerated() where mark == "#" {
                    context.fill(Path(CGRect(x: CGFloat(column) * pixel, y: CGFloat(row) * pixel, width: pixel + 0.35, height: pixel + 0.35)),
                                 with: .color(Color(red: 0.94, green: 0.34, blue: 0.48)))
                }
            }
        }
        .frame(width: pixel * 7, height: pixel * 6)
        .accessibilityHidden(true)
    }
}
