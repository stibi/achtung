// Renders the krysa's coffee break, Live's "All caught up" scene, as looping GIFs into
// macos/Icon/coffee-break/: light and dark, at 8 and 4 px per pixel. The scene and its
// colours are the app's own (CoffeeBreakScene.swift, CoffeeBreakPalette.swift), so the
// GIFs match the app. Run macos/scripts/render-coffee-break.sh, which compiles the three
// together.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum RenderCoffeeBreak {
    /// Ten frames a second: GIF delays are in hundredths, so 0.1 s is exact.
    static let framesPerSecond = 10

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw RenderError("Usage: render-coffee-break <output directory>")
        }
        let output = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let frames = loop()
        for (name, palette) in [("light", CoffeeBreakPalette.light), ("dark", .dark)] {
            for scale in [8, 4] {
                let suffix = scale == 8 ? "" : "-small"
                let file = output.appending(path: "coffee-break-\(name)\(suffix).gif")
                try write(frames, palette: palette, scale: scale, to: file)
            }
        }
    }

    /// The loop's frames as colour grids, a run of identical frames merged into one with
    /// their summed length, in tenths of a second.
    static func loop() -> [(scene: CoffeeBreakScene, tenths: Int)] {
        var frames: [(scene: CoffeeBreakScene, tenths: Int)] = []
        let count = Int(CoffeeBreakScene.loop) * framesPerSecond
        for index in 0..<count {
            let scene = CoffeeBreakScene(time: Double(index) / Double(framesPerSecond))
            if let last = frames.last, last.scene.pixels == scene.pixels,
                last.scene.steam == scene.steam
            {
                frames[frames.count - 1].tenths += 1
            } else {
                frames.append((scene, 1))
            }
        }
        return frames
    }

    static func write(
        _ frames: [(scene: CoffeeBreakScene, tenths: Int)], palette: CoffeeBreakPalette,
        scale: Int, to file: URL
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                file as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else {
            throw RenderError("Can't write \(file.path)")
        }
        let loopForever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loopForever as CFDictionary)
        for frame in frames {
            let seconds = Double(frame.tenths) / Double(framesPerSecond)
            let delay = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: seconds,
                    kCGImagePropertyGIFUnclampedDelayTime: seconds,
                ]
            ]
            let image = try render(frame.scene, palette: palette, scale: scale)
            CGImageDestinationAddImage(destination, image, delay as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError("Can't finish \(file.path)")
        }
        print("\(file.lastPathComponent): \(frames.count) frames")
    }

    /// The scene as the app draws it: wall, floor, paints, then steam blended over what's
    /// beneath, opaque, since a GIF has no partial transparency.
    static func render(_ scene: CoffeeBreakScene, palette: CoffeeBreakPalette, scale: Int)
        throws -> CGImage
    {
        let columns = CoffeeBreakScene.columns
        let rows = CoffeeBreakScene.rows
        var grid = [Int](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let spot = CoffeeBreakScene.Pixel(column: column, row: row)
                var color = row < CoffeeBreakScene.floorRow ? palette.wall : palette.floor
                if let paint = scene.pixels[spot] {
                    guard let hex = CoffeeBreakPalette.paints[paint] else {
                        throw RenderError("No colour for \(paint)")
                    }
                    color = hex
                }
                if let strength = scene.steam[spot] {
                    color = blend(
                        palette.steam, over: color,
                        opacity: CoffeeBreakPalette.steamOpacity(strength))
                }
                grid[row * columns + column] = color
            }
        }
        let width = columns * scale
        let height = rows * scale
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for line in 0..<height {
            for dot in 0..<width {
                let color = grid[(line / scale) * columns + dot / scale]
                let offset = (line * width + dot) * 4
                bytes[offset] = UInt8((color >> 16) & 0xFF)
                bytes[offset + 1] = UInt8((color >> 8) & 0xFF)
                bytes[offset + 2] = UInt8(color & 0xFF)
            }
        }
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw RenderError("Can't make a \(width)×\(height) image")
        }
        return image
    }
}

/// `color` at `opacity` over `background`, as one opaque colour, as a GIF needs.
func blend(_ color: Int, over background: Int, opacity: Double) -> Int {
    [16, 8, 0].reduce(0) { result, shift in
        let top = Double((color >> shift) & 0xFF)
        let bottom = Double((background >> shift) & 0xFF)
        let channel = Int((top * opacity + bottom * (1 - opacity)).rounded())
        return result | (channel << shift)
    }
}

struct RenderError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
