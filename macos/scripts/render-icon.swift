// Renders macos/Icon/AppIcon.svg into every size of the app's icon set, with macOS's own
// SVG renderer. Run after changing AppIcon.svg: swift macos/scripts/render-icon.swift
import AppKit

let macos = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = macos.appending(path: "Icon/AppIcon.svg")
let iconSet = macos.appending(path: "Achtung/Assets.xcassets/AppIcon.appiconset")

guard let image = NSImage(contentsOf: source) else {
    fatalError("Can't read \(source.path)")
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else {
        fatalError("Can't create a \(pixels) px bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Can't encode the \(pixels) px icon")
    }
    try png.write(to: iconSet.appending(path: "icon_\(pixels).png"))
    print("icon_\(pixels).png")
}
