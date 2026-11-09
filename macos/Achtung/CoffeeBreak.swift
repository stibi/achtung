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
            guard let hex = CoffeeBreakPalette.paints[paint] else {
                preconditionFailure("CoffeeBreakPalette.paints has no colour for \(paint)")
            }
            graphics.fill(path, with: .color(Color(hex: hex)))
        }
        // Steam in a few strengths (`CoffeeBreakPalette.steamOpacity`).
        var byOpacity: [Double: Path] = [:]
        for (spot, strength) in scene.steam {
            byOpacity[CoffeeBreakPalette.steamOpacity(strength), default: Path()]
                .addRect(rect(spot))
        }
        for (opacity, path) in byOpacity {
            graphics.fill(path, with: .color(Color(hex: palette.steam).opacity(opacity)))
        }
    }

    private var palette: CoffeeBreakPalette { colorScheme == .dark ? .dark : .light }
    private var wall: Color { Color(hex: palette.wall) }
    private var floorColor: Color { Color(hex: palette.floor) }
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
