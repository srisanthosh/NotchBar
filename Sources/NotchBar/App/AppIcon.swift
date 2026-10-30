import AppKit
import SwiftUI

/// The app icon, drawn in code so it can be regenerated at every size:
/// `NotchBar --make-icon Resources/AppIcon.iconset && iconutil -c icns Resources/AppIcon.iconset`.
struct AppIconArt: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 1024
            ZStack {
                // macOS icon grid: an 824-point rounded square centred on a 1024 canvas.
                RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.22, blue: 0.78), Color(red: 0.13, green: 0.1, blue: 0.38)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 6 * s))
                    .frame(width: 824 * s, height: 824 * s)
                    .shadow(color: .black.opacity(0.35), radius: 20 * s, y: 12 * s)

                // The notch, opened into a small island with waves and the Claude spark.
                Capsule()
                    .fill(.black)
                    .frame(width: 560 * s, height: 170 * s)
                    .overlay {
                        HStack {
                            HStack(spacing: 16 * s) {
                                ForEach([0.55, 1.0, 0.7, 0.85], id: \.self) { h in
                                    Capsule().fill(LinearGradient(colors: [.white, Color(red: 0.8, green: 0.7, blue: 1)],
                                                                  startPoint: .top, endPoint: .bottom))
                                        .frame(width: 20 * s, height: 86 * s * h)
                                }
                            }
                            Spacer()
                            ClaudeSpark()
                                .stroke(Color.claude, style: StrokeStyle(lineWidth: 15 * s, lineCap: .round))
                                .frame(width: 96 * s, height: 96 * s)
                        }
                        .padding(.horizontal, 62 * s)
                    }
                    .offset(y: -150 * s)

                // A soft glow under the island suggests the screen.
                Capsule()
                    .fill(.white.opacity(0.08))
                    .frame(width: 420 * s, height: 26 * s)
                    .offset(y: 150 * s)
                Capsule()
                    .fill(.white.opacity(0.05))
                    .frame(width: 300 * s, height: 26 * s)
                    .offset(y: 210 * s)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    /// Writes the PNG sizes `iconutil` expects into an `.iconset` folder.
    @MainActor
    static func writeIconset(to path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: AppIconArt().frame(width: CGFloat(base), height: CGFloat(base)))
                renderer.scale = CGFloat(scale)
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png.write(to: folder.appendingPathComponent(name))
            }
        }
        print("Wrote \(folder.path)")
    }
}
