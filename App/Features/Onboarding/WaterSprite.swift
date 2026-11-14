import SwiftUI

/// The Suijin water sprite: a pixel droplet on a 12×14 grid with a curled tip, two eyes and two small boots. One
/// colour per kind of session, as in the promo film. Pure value: a pose in, the coloured cells out.
struct WaterSprite: Equatable {
    enum Tint: String, CaseIterable {
        /// Any other agent, Claude Code, Codex, a shell.
        case aqua, claude, codex, shell
    }
    enum Eyes { case open, happy, blink, wide }
    enum Arms { case down, up, wave }
    enum Legs { case stand, tuck, sit }
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

/// A sprite that lives a little: it blinks, and hops now and then (idle), keeps jumping with happy eyes (cheering)
/// or sits with its legs hanging (sitting). With Reduce Motion it holds one still pose.
struct LivelySprite: View {
    enum Mood { case idle, cheering, sitting }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: WaterSprite.Tint
    var pixel: CGFloat = 6
    var mood = Mood.idle
    /// Seconds this sprite runs ahead of the others, so a row of them does not move in step.
    var phase: Double = 0

    var body: some View {
        if reduceMotion {
            frame(at: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                frame(at: timeline.date.timeIntervalSinceReferenceDate + phase)
            }
        }
    }

    /// The pose and lift at `time`; nil is the still pose.
    private func frame(at time: Double?) -> some View {
        let pose = LivelySprite.pose(tint: tint, mood: mood, time: time)
        return WaterSpriteView(sprite: pose.sprite, pixel: pixel)
            .offset(y: -pose.lift * pixel)
    }

    /// The sprite and how many pixels it is off the ground at `time`.
    static func pose(tint: WaterSprite.Tint, mood: Mood, time: Double?) -> (sprite: WaterSprite, lift: Double) {
        var sprite = WaterSprite(tint: tint)
        var lift = 0.0
        let blinking = time.map { $0.truncatingRemainder(dividingBy: 3.4) < 0.14 } ?? false
        switch mood {
        case .idle:
            sprite.eyes = blinking ? .blink : .open
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
            sprite.eyes = blinking ? .blink : .open
        }
        return (sprite, lift)
    }
}
