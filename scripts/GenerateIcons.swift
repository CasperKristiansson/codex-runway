import AppKit
import Foundation

// Render every delivery size directly from the approved vector source.
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let icon = NSImage(contentsOf: source) else { fatalError("Cannot load icon SVG") }

func render(_ image: NSImage, pixels: Int, name: String, directory: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(icon, pixels: size, name: "icon_\(size)x\(size).png", directory: iconset)
    try render(icon, pixels: size * 2, name: "icon_\(size)x\(size)@2x.png", directory: iconset)
}

// Extract the original mark as vectors, not by cropping a raster image.
let document = try XMLDocument(contentsOf: source)
let root = document.rootElement()!
for tile in try document.nodes(forXPath: "//*[@id='icon-tile']") { tile.detach() }
root.attribute(forName: "viewBox")!.stringValue = "180 175 664 664"
guard let mark = NSImage(data: document.xmlData) else { fatalError("Cannot load account mark") }
try render(mark, pixels: 44, name: "AccountMark.png", directory: output)
try render(mark, pixels: 88, name: "AccountMark@2x.png", directory: output)
for use in try document.nodes(forXPath: "//*[@id='account-mark']/*") {
    (use as! XMLElement).attribute(forName: "fill")!.stringValue = "#000000"
}
let group = (try document.nodes(forXPath: "//*[@id='account-mark']").first as! XMLElement)
group.attribute(forName: "stroke")!.stringValue = "none"
guard let template = NSImage(data: document.xmlData) else { fatalError("Cannot load menu bar mark") }
try render(template, pixels: 18, name: "MenuBarMark.png", directory: output)
try render(template, pixels: 36, name: "MenuBarMark@2x.png", directory: output)
