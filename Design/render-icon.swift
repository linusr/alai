// Renders the Alai app icon variants: swift Design/render-icon.swift <output-directory>
import AppKit
import CoreGraphics

enum Variant: String, CaseIterable {
    case light = "AppIcon"
    case dark = "AppIcon-Dark"
    case tinted = "AppIcon-Tinted"
}

let size = 1024
let outputDirectory = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A wave band across the icon: a smooth crest-and-trough curve, filled down to the bottom edge.
func wave(baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, wavelength: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let s = CGFloat(size)
    path.move(to: CGPoint(x: -20, y: 0))
    path.addLine(to: CGPoint(x: -20, y: baseline))
    var x: CGFloat = -20
    while x <= s + 20 {
        let y = baseline + amplitude * sin((x / wavelength + phase) * 2 * .pi)
        path.addLine(to: CGPoint(x: x, y: y))
        x += 4
    }
    path.addLine(to: CGPoint(x: s + 20, y: 0))
    path.closeSubpath()
    return path
}

func render(_ variant: Variant) throws {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // App Store Connect rejects a primary icon with an alpha channel; only the tinted variant needs transparency
    let alpha: CGImageAlphaInfo = variant == .tinted ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: alpha.rawValue) else { return }

    // Background: blue gradient (light), deep navy (dark), transparent (tinted, the system supplies the color)
    switch variant {
    case .light:
        let gradient = CGGradient(colorsSpace: space, colors: [color(0x60A5FA), color(0x2563EB), color(0x1E3A8A)] as CFArray, locations: [0, 0.5, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s * 0.3, y: 0), options: [])
    case .dark:
        let gradient = CGGradient(colorsSpace: space, colors: [color(0x111C33), color(0x060A14)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    case .tinted:
        break
    }

    // Notification dot: a rising sun / signal above the waves
    let dotColor: CGColor = switch variant {
    case .light: color(0xFFFFFF)
    case .dark: color(0x93C5FD)
    case .tinted: color(0xFFFFFF)
    }
    let dotCenter = CGPoint(x: s * 0.5, y: s * 0.64)
    for (radius, alpha) in [(s * 0.26, 0.10), (s * 0.19, 0.16)] as [(CGFloat, CGFloat)] {
        context.setFillColor(dotColor.copy(alpha: alpha)!)
        context.fillEllipse(in: CGRect(x: dotCenter.x - radius, y: dotCenter.y - radius, width: radius * 2, height: radius * 2))
    }
    let core = s * 0.115
    context.setFillColor(dotColor)
    context.fillEllipse(in: CGRect(x: dotCenter.x - core, y: dotCenter.y - core, width: core * 2, height: core * 2))

    // Three layered waves, back to front
    let waves: [(baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, alpha: CGFloat)] = [
        (s * 0.44, s * 0.035, 0.10, 0.35),
        (s * 0.35, s * 0.045, 0.45, 0.60),
        (s * 0.25, s * 0.055, 0.80, 1.00),
    ]
    let waveColor: CGColor = switch variant {
    case .light: color(0xDBEAFE)
    case .dark: color(0x60A5FA)
    case .tinted: color(0xFFFFFF)
    }
    for band in waves {
        context.setFillColor(waveColor.copy(alpha: band.alpha)!)
        context.addPath(wave(baseline: band.baseline, amplitude: band.amplitude, phase: band.phase, wavelength: s * 0.55))
        context.fillPath()
    }

    guard let image = context.makeImage() else { return }
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: outputDirectory.appending(path: "\(variant.rawValue).png"))
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for variant in Variant.allCases {
    try render(variant)
}
print("Rendered \(Variant.allCases.count) icons to \(outputDirectory.path())")
