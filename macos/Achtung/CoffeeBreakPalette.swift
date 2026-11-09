import Foundation

/// The coffee break's colours as 0xRRGGBB, for the app's view (`CoffeeBreak`) and for
/// macos/scripts/render-coffee-break.swift, which exports the scene as GIFs: one palette,
/// so the export can't drift from the app. Foundation only, for that script.
struct CoffeeBreakPalette {
    /// The room behind the krysa.
    let wall: Int
    let floor: Int
    /// The steam's colour at full strength; it's drawn translucent (`steamOpacity`).
    let steam: Int

    static let light = CoffeeBreakPalette(wall: 0xE6DFD4, floor: 0xCFC4B4, steam: 0xA89E91)
    /// Light steam on the dark wall; on the light one white barely shows, hence warm grey.
    static let dark = CoffeeBreakPalette(wall: 0x3A3633, floor: 0x2C2927, steam: 0xD0D0D0)

    /// The app icon's palette (macos/Icon/AppIcon.svg), and the room's, in both schemes.
    static let paints: [CoffeeBreakScene.Paint: Int] = [
        .outline: 0x202020, .fur: 0x545454, .shade: 0x444141, .ear: 0xC87575,
        .earInside: 0xE6ABAB, .foot: 0x895526, .eye: 0x0A0A0A, .mug: 0xF2F2F2,
        .green: 0x29DF2B, .wood: 0xA06A3C, .woodDark: 0x7A4C26, .frame: 0x8A8A8A,
        .extinguisher: 0xD83A34, .extinguisherShade: 0x9E2422,
    ]

    /// A wisp's strength (0...1) drawn in four steps, which is all a pixel wisp needs.
    static func steamOpacity(_ strength: Double) -> Double {
        (strength * 4).rounded(.up) / 4
    }
}
