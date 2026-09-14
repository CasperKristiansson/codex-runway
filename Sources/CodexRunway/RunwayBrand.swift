import AppKit

@MainActor
enum RunwayBrand {
    static let accountMark = load("AccountMark", size: 22)
    static let menuBarMark: NSImage = {
        let image = load("MenuBarMark", size: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Codex Runway"
        return image
    }()

    private static func load(_ name: String, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        for suffix in ["", "@2x"] {
            if let url = Bundle.main.url(forResource: name + suffix, withExtension: "png"),
               let data = try? Data(contentsOf: url),
               let representation = NSBitmapImageRep(data: data) {
                representation.size = image.size
                image.addRepresentation(representation)
            }
        }
        return image
    }
}
