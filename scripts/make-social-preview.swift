// Renders the 1280 × 640 image GitHub shows when the repository is shared.
// Usage: swift scripts/make-social-preview.swift docs/social-preview.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "docs/social-preview.png"
let size = NSSize(width: 1280, height: 640)
let image = NSImage(size: size)
image.lockFocus()

// A near-black background with a faint warm glow, like the notch at night.
NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
NSGradient(colors: [NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.22), .clear])!
    .draw(fromCenter: NSPoint(x: 300, y: 330), radius: 0, toCenter: NSPoint(x: 300, y: 330), radius: 520, options: [])

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: NSPoint) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    (text as NSString).draw(at: point, withAttributes: attributes)
}

if let icon = NSImage(contentsOfFile: "docs/icon.png") {
    icon.draw(in: NSRect(x: 72, y: 400, width: 132, height: 132))
}
draw("NotchBar", size: 76, weight: .bold, color: .white, at: NSPoint(x: 70, y: 290))
draw("Your MacBook's notch,", size: 32, weight: .medium, color: NSColor(white: 1, alpha: 0.72), at: NSPoint(x: 74, y: 236))
draw("put to work.", size: 32, weight: .medium, color: NSColor(white: 1, alpha: 0.72), at: NSPoint(x: 74, y: 196))
draw("Open source  ·  macOS 14+  ·  About 0.1% CPU", size: 20, weight: .regular,
     color: NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), at: NSPoint(x: 76, y: 120))

if let shot = NSImage(contentsOfFile: "docs/screenshots/00-home.png") {
    let width: CGFloat = 690
    let height = width * shot.size.height / shot.size.width
    let frame = NSRect(x: 540, y: (size.height - height) / 2, width: width, height: height)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22)
    // A soft shadow under rounded corners, so the screenshot sits like a window.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    shot.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
}

image.unlockFocus()
let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
bitmap.size = size
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
