import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 210, yRadius: 210).fill()
        let mark = "f/" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 570, weight: .black),
            .foregroundColor: NSColor(calibratedRed: 0.80, green: 0.96, blue: 0.35, alpha: 1),
            .kern: -45
        ]
        let markSize = mark.size(withAttributes: attrs)
        mark.draw(at: NSPoint(x: (1024 - markSize.width) / 2 - 15, y: (1024 - markSize.height) / 2 + 10), withAttributes: attrs)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
