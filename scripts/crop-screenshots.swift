// Crops NotchBar snapshots to the notch and its shadow, for the README.
// Usage: swift scripts/crop-screenshots.swift <snapshot folder> <output folder> name...
import AppKit

let args = CommandLine.arguments.dropFirst()
guard args.count >= 3 else { print("usage: crop-screenshots <in> <out> name..."); exit(1) }
let input = URL(fileURLWithPath: args[args.startIndex])
let output = URL(fileURLWithPath: args[args.startIndex + 1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for name in args.dropFirst(2) {
    guard let image = NSImage(contentsOf: input.appendingPathComponent(name + ".png")),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { print("skip", name); continue }
    let width = cg.width, height = cg.height, row = cg.bytesPerRow, step = cg.bitsPerPixel / 8
    // The notch is pure black; the wallpaper behind it never is.
    var minX = width, maxX = 0, maxY = 0
    for y in 0..<height {
        for x in stride(from: 0, to: width, by: 2) {
            let p = y * row + x * step
            if bytes[p] < 8 && bytes[p + 1] < 8 && bytes[p + 2] < 8 {
                minX = min(minX, x); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    let margin = 56
    let rect = CGRect(x: max(0, minX - margin), y: 0, width: min(width, maxX + margin) - max(0, minX - margin),
                      height: min(height, maxY + margin))
    guard let cropped = cg.cropping(to: rect) else { continue }
    let rep = NSBitmapImageRep(cgImage: cropped)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    print(name, Int(rect.width), "x", Int(rect.height))
}
