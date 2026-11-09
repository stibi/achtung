import SwiftUI

/// The krysa on a coffee break, above Live's "All caught up": a calm room, an unused fire
/// extinguisher in the corner, and the krysa sipping its coffee every few seconds
/// (`CoffeeBreakScene`). Drawn as pixels, like the app icon, on its own wall and floor so
/// it reads in light and dark. It only moves while its window is the key window, so a Mac
/// that keeps Achtung open on "All caught up" all day isn't redrawing it all day. With
/// Reduce Motion (unless Settings says to animate anyway), or in the background, it's a
/// still frame: the mug resting on the table.
struct CoffeeBreak: View {
    /// Four points to a pixel.
    static let size = CGSize(
        width: CoffeeBreakScene.columns * 4, height: CoffeeBreakScene.rows * 4)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The user's choice in Settings to animate despite Reduce Motion (`MotionSetting`).
    @AppStorage(MotionSetting.key) private var animatesDespiteReduceMotion = false
    @Environment(\.controlActiveState) private var windowState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            // A still frame is a plain Canvas: a paused TimelineView keeps the window
            // updating, at a few percent of a core.
            if (reduceMotion && !animatesDespiteReduceMotion) || windowState != .key {
                canvas(CoffeeBreakScene(time: 0))
            } else {
                TimelineView(CoffeeBreakSchedule()) { context in
                    canvas(CoffeeBreakScene(time: context.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(.rect(cornerRadius: 10))
        // Decoration: the text below says what it means.
        .accessibilityHidden(true)
    }

    private func canvas(_ scene: CoffeeBreakScene) -> some View {
        Canvas { graphics, size in
            draw(scene, in: &graphics, size: size)
        }
    }

    private func draw(_ scene: CoffeeBreakScene, in graphics: inout GraphicsContext, size: CGSize) {
        let pixel = size.width / CGFloat(CoffeeBreakScene.columns)
        let floor = CGFloat(CoffeeBreakScene.floorRow) * pixel
        graphics.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: floor)), with: .color(wall))
        graphics.fill(
            Path(CGRect(x: 0, y: floor, width: size.width, height: size.height - floor)),
            with: .color(floorColor))
        func rect(_ spot: CoffeeBreakScene.Pixel) -> CGRect {
            CGRect(
                x: CGFloat(spot.column) * pixel, y: CGFloat(spot.row) * pixel, width: pixel,
                height: pixel)
        }
        // One path per colour, a dozen fills a frame rather than one per pixel.
        var byPaint: [CoffeeBreakScene.Paint: Path] = [:]
        for (spot, paint) in scene.pixels {
            byPaint[paint, default: Path()].addRect(rect(spot))
        }
        for (paint, path) in byPaint {
            guard let color = Self.colors[paint] else {
                preconditionFailure("CoffeeBreak.colors has no colour for \(paint)")
            }
            graphics.fill(path, with: .color(color))
        }
        // Steam in four strengths, which is all a pixel wisp needs.
        var byStrength: [Int: Path] = [:]
        for (spot, strength) in scene.steam {
            byStrength[Int((strength * 4).rounded(.up)), default: Path()].addRect(rect(spot))
        }
        for (strength, path) in byStrength {
            graphics.fill(path, with: .color(steam.opacity(Double(strength) / 4)))
        }
    }

    private var isDark: Bool { colorScheme == .dark }
    private var wall: Color { isDark ? Color(hex: 0x3A3633) : Color(hex: 0xE6DFD4) }
    private var floorColor: Color { isDark ? Color(hex: 0x2C2927) : Color(hex: 0xCFC4B4) }
    /// Light on the dark wall, a warm grey on the light one, where white barely shows.
    private var steam: Color { isDark ? Color(hex: 0xD0D0D0) : Color(hex: 0xA89E91) }

    /// The app icon's palette (macos/Icon/AppIcon.svg), and the room's.
    private static let colors: [CoffeeBreakScene.Paint: Color] = [
        .outline: 0x202020, .fur: 0x545454, .shade: 0x444141, .ear: 0xC87575,
        .earInside: 0xE6ABAB, .foot: 0x895526, .eye: 0x0A0A0A, .mug: 0xF2F2F2,
        .green: 0x29DF2B, .wood: 0xA06A3C, .woodDark: 0x7A4C26, .frame: 0x8A8A8A,
        .extinguisher: 0xD83A34, .extinguisherShade: 0x9E2422,
    ].mapValues { Color(hex: $0) }
}

/// Frames only when something changes: eight a second while the mug moves, four while only
/// the steam drifts, none while the krysa holds the mug at its mouth (no steam then). When
/// the system asks for low frequency, one a second.
private struct CoffeeBreakSchedule: TimelineSchedule {
    struct Entries: Sequence, IteratorProtocol {
        var date: Date
        let lowFrequency: Bool

        mutating func next() -> Date? {
            let current = date
            date += lowFrequency ? 1 : Self.step(at: current)
            return current
        }

        private static func step(at date: Date) -> TimeInterval {
            let phase = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: CoffeeBreakScene.loop)
            if CoffeeBreakScene.holding.contains(phase) {
                // At least a frame's length: at today's dates a Double is only precise to
                // about 1e-7 s, so a jump to the hold's exact end could round to no step at
                // all and stall the schedule.
                return Swift.max(CoffeeBreakScene.holding.upperBound - phase, 1.0 / 8)
            }
            let moving =
                CoffeeBreakScene.lifting.contains(phase)
                || CoffeeBreakScene.lowering.contains(phase)
            return moving ? 1.0 / 8 : 1.0 / 4
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(date: startDate, lowFrequency: mode == .lowFrequency)
    }
}

extension Color {
    /// An sRGB colour from 0xRRGGBB, as the icon's SVG writes them.
    fileprivate init(hex: Int) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

#Preview("Light") {
    CoffeeBreak()
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    CoffeeBreak()
        .padding()
        .preferredColorScheme(.dark)
}
