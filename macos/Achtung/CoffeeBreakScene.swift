import Foundation

/// One moment of the krysa's coffee break, as pixels on a grid: the room, the krysa (the
/// app icon's pixel rat, see macos/Icon/) on a stool at a table, a fire extinguisher in the
/// corner, and the mug, which the krysa lifts for a sip every few seconds. `CoffeeBreak`
/// draws it; this is only where each pixel goes.
struct CoffeeBreakScene {
    static let columns = 56
    static let rows = 30
    /// The floor starts at this row; the wall is above it.
    static let floorRow = 26
    /// One sip and the pause before the next.
    static let loop: TimeInterval = 7
    /// Within the loop: the mug goes up, stays at the krysa's mouth, comes back down.
    static let lifting: Range<TimeInterval> = 3.4..<4.2
    static let holding: Range<TimeInterval> = 4.2..<5.6
    static let lowering: Range<TimeInterval> = 5.6..<6.4

    /// What a pixel is painted with; `CoffeeBreak` picks the colour.
    enum Paint: Character {
        case outline = "o"
        case fur = "L"
        case shade = "D"
        case ear = "p"
        case earInside = "P"
        case foot = "b"
        case eye = "k"
        case mug = "w"
        case green = "g"
        case wood = "T"
        case woodDark = "t"
        case frame = "m"
        case extinguisher = "r"
        case extinguisherShade = "R"
    }

    struct Pixel: Hashable {
        let column: Int
        let row: Int
    }

    /// Later paint covers earlier paint, as layers do.
    private(set) var pixels: [Pixel: Paint] = [:]
    /// Wisps of steam above the mug, from 0 (gone) to 1.
    private(set) var steam: [Pixel: Double] = [:]

    /// What doesn't move, the room and the krysa, painted once rather than every frame.
    private static let still: [Pixel: Paint] = {
        var scene = CoffeeBreakScene()
        scene.paintRoom()
        scene.paintKrysa()
        return scene.pixels
    }()

    private init() {}

    /// The scene `time` seconds into any loop.
    init(time: TimeInterval) {
        let phase = time.truncatingRemainder(dividingBy: Self.loop)
        let lift = Self.lift(at: phase)
        pixels = Self.still
        if lift > 0.95 {
            // Eyes closed, savouring it: a lid over the eye.
            pixels[Pixel(column: Self.krysa.column + 15, row: Self.krysa.row + 5)] = .shade
        }
        // From its place on the table up to the krysa's snout.
        let mug = Pixel(
            column: Self.mugOnTable.column
                + Int((Double(Self.mugAtMouth.column - Self.mugOnTable.column) * lift).rounded()),
            row: Self.mugOnTable.row
                + Int((Double(Self.mugAtMouth.row - Self.mugOnTable.row) * lift).rounded()))
        // The paw shows through the handle.
        paintArm(to: Pixel(column: mug.column + 1, row: mug.row + 2))
        paint(Self.mugSprite, at: mug)
        if lift < 0.95 {
            paintSteam(above: mug, phase: phase)
        }
    }

    /// Where the mug's top left corner is: resting on the table, and lifted to the snout.
    private static let mugOnTable = Pixel(column: 30, row: 12)
    private static let mugAtMouth = Pixel(column: 24, row: 8)

    /// How far the mug is from the table (0) to the krysa's mouth (1): resting, lifted,
    /// held for a sip, put back, eased in and out.
    static func lift(at phase: TimeInterval) -> Double {
        let raw: Double =
            switch phase {
            case ..<lifting.lowerBound: 0
            case lifting: (phase - lifting.lowerBound) / (lifting.upperBound - lifting.lowerBound)
            case holding: 1
            case lowering:
                1 - (phase - lowering.lowerBound) / (lowering.upperBound - lowering.lowerBound)
            default: 0
            }
        return raw * raw * (3 - 2 * raw)
    }

    // MARK: - Sprites

    /// Where the krysa's sprite starts.
    private static let krysa = Pixel(column: 7, row: 4)

    private static let krysaSprite = [
        "..........oo..........",
        ".........oPPo.........",
        ".........oPpLooo......",
        "........oLLLLLLLoo....",
        ".......oLLLLLLLLLLo...",
        ".......oLLLLLLLkLLLo..",
        ".......oLLLLLLLLLLLLob",
        "........oDLLLLLLLLLoo.",
        "........oDDLLLLLLoo...",
        ".......oDDLLLLLLLo....",
        "......oDDLLLLLLLLo....",
        "......oDDLLLLLLLLLo...",
        "......oDDDLLLLLLLLo...",
        ".......oDDDLLLLLLo....",
        "........ooDDDDDDoo....",
        ".........bb....bb.....",
    ]

    /// From the krysa's back, down the stool and curled on the floor.
    private static let tail = [
        (5, 13), (4, 14), (3, 15), (2, 16), (2, 17), (2, 18), (2, 19), (2, 20), (3, 21),
        (4, 21), (5, 21), (6, 20),
    ]

    /// Handle on the left, towards the krysa, and a green band.
    private static let mugSprite = ["..oooo", "oowwwo", "o.wggo", "oowwwo", "..oooo"]

    private static let stool = [
        "oooooooooooo", ".t........t.", ".t........t.", ".t........t.", ".t........t.",
        ".t........t.", ".t........t.",
    ]

    private static let extinguisher = [
        "..oo....", ".o..oo..", ".o.rrrR.", ".o.rrrR.", "...rrrR.", "...wwww.",
        "...rrrR.", "...rrrR.", "...rrrR.", "...rrrR.", "...rrrR.",
    ]

    /// A framed green check on the wall: everything's fine, really.
    private static let picture = [
        "mmmmmmmm", "m......m", "m....g.m", "m.g.g..m", "m..g...m", "m......m", "mmmmmmmm",
    ]

    // MARK: - Painting

    private mutating func paintRoom() {
        paint(Self.picture, at: Pixel(column: 36, row: 3))
        for column in 0..<Self.columns {
            pixels[Pixel(column: column, row: Self.floorRow)] = .woodDark
        }
        // The table: its top, and two legs.
        for column in 24..<40 {
            pixels[Pixel(column: column, row: 17)] = .wood
            pixels[Pixel(column: column, row: 18)] = .woodDark
        }
        for row in 19..<Self.floorRow {
            pixels[Pixel(column: 26, row: row)] = .woodDark
            pixels[Pixel(column: 37, row: row)] = .woodDark
        }
        paint(Self.extinguisher, at: Pixel(column: 48, row: 15))
        paint(Self.stool, at: Pixel(column: 11, row: 19))
    }

    private mutating func paintKrysa() {
        for (column, row) in Self.tail {
            pixels[Pixel(column: Self.krysa.column + column, row: Self.krysa.row + row)] = .ear
        }
        paint(Self.krysaSprite, at: Self.krysa)
    }

    /// From the shoulder to the paw on the mug's handle.
    private mutating func paintArm(to paw: Pixel) {
        let shoulder = Pixel(column: Self.krysa.column + 12, row: Self.krysa.row + 10)
        let across = paw.column - shoulder.column
        let down = paw.row - shoulder.row
        let steps = max(abs(across), abs(down), 1)
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let column = shoulder.column + Int((Double(across) * fraction).rounded())
            let row = shoulder.row + Int((Double(down) * fraction).rounded())
            pixels[Pixel(column: column, row: row)] = .shade
            // An outline below the arm against the wall; over the krysa's fur it would draw
            // a stripe across its belly.
            let below = Pixel(column: column, row: row + 1)
            if pixels[below] != .fur && pixels[below] != .shade {
                pixels[below] = .outline
            }
        }
        pixels[paw] = .earInside
    }

    /// Three wisps that rise from the mug, sway and fade.
    private mutating func paintSteam(above mug: Pixel, phase: TimeInterval) {
        for wisp in 0..<3 {
            for puff in 0..<4 {
                let age = (phase * 1.6 + Double(wisp) * 0.7 + Double(puff) * 0.9)
                    .truncatingRemainder(dividingBy: 3)
                let sway = Int((sin(age * 3 + Double(wisp)) * 0.8).rounded())
                let pixel = Pixel(
                    column: mug.column + 2 + wisp + sway, row: mug.row - 1 - Int(age * 2))
                steam[pixel] = max(steam[pixel] ?? 0, 1 - age / 3)
            }
        }
    }

    private mutating func paint(_ sprite: [String], at origin: Pixel) {
        for (row, line) in sprite.enumerated() {
            for (column, character) in line.enumerated() {
                if let paint = Paint(rawValue: character) {
                    pixels[Pixel(column: origin.column + column, row: origin.row + row)] = paint
                }
            }
        }
    }
}
