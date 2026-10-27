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

// MARK: - Icon Composer document

/// SVG path for a wave band in Icon Composer's top-left-origin coordinates.
func waveSVG(baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, wavelength: CGFloat) -> String {
    let s = CGFloat(size)
    var points = [String]()
    var x: CGFloat = -20
    while x <= s + 20 {
        let y = baseline + amplitude * sin((x / wavelength + phase) * 2 * .pi)
        points.append(String(format: "%.1f %.1f", x, s - y))
        x += 4
    }
    return "M-20 \(Int(s) + 20) L" + points.joined(separator: " L") + " L\(Int(s) + 20) \(Int(s) + 20) Z"
}

func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(size) \(size)\">\(body)</svg>\n"
}

func hexString(_ hex: UInt32) -> String {
    let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
    return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", r, g, b)
}

/// Writes AppIcon.icon: background fill plus sun and wave layers, so the system renders the
/// Liquid Glass, clear and tinted appearances from the layers rather than a flat image.
func writeIconDocument() throws {
    let s = CGFloat(size)
    let document = outputDirectory.appending(path: "AppIcon.icon")
    let assets = document.appending(path: "Assets")
    try? FileManager.default.removeItem(at: document)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    // Layer opacity carries the translucency, since a layer's fill replaces the SVG's own colors
    let center = (x: s * 0.5, y: s - s * 0.64)
    let sun: [(name: String, radius: CGFloat, opacity: Double)] = [("Sun", s * 0.115, 1), ("Halo Inner", s * 0.19, 0.16), ("Halo Outer", s * 0.26, 0.10)]
    let waves: [(name: String, baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, opacity: Double)] = [
        ("Wave Front", s * 0.25, s * 0.055, 0.80, 1),
        ("Wave Middle", s * 0.35, s * 0.045, 0.45, 0.60),
        ("Wave Back", s * 0.44, s * 0.035, 0.10, 0.35),
    ]
    for disc in sun {
        try svg("<circle cx=\"\(center.x)\" cy=\"\(center.y)\" r=\"\(disc.radius)\" fill=\"#fff\"/>")
            .write(to: assets.appending(path: "\(disc.name).svg"), atomically: true, encoding: .utf8)
    }
    for band in waves {
        try svg("<path d=\"\(waveSVG(baseline: band.baseline, amplitude: band.amplitude, phase: band.phase, wavelength: s * 0.55))\" fill=\"#fff\"/>")
            .write(to: assets.appending(path: "\(band.name).svg"), atomically: true, encoding: .utf8)
    }

    func layer(_ name: String, opacity: Double, light: UInt32, dark: UInt32) -> [String: Any] {
        [
            "name": name,
            "image-name": "\(name).svg",
            "opacity": opacity,
            "fill-specializations": [
                ["value": ["solid": hexString(light)]],
                ["appearance": "dark", "value": ["solid": hexString(dark)]],
            ],
        ]
    }
    // Groups are listed front to back
    let icon: [String: Any] = [
        "fill-specializations": [
            ["value": ["linear-gradient": [hexString(0x60A5FA), hexString(0x1E3A8A)], "orientation": ["start": ["x": 0.2, "y": 0], "stop": ["x": 0.5, "y": 1]]]],
            ["appearance": "dark", "value": ["linear-gradient": [hexString(0x111C33), hexString(0x060A14)], "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]]]],
        ],
        "groups": [
            ["name": "Waves", "layers": waves.map { layer($0.name, opacity: $0.opacity, light: 0xDBEAFE, dark: 0x60A5FA) },
             "shadow": ["kind": "neutral", "opacity": 0.5], "translucency": ["enabled": true, "value": 0.3]],
            ["name": "Sun", "layers": sun.map { layer($0.name, opacity: $0.opacity, light: 0xFFFFFF, dark: 0x93C5FD) },
             "shadow": ["kind": "neutral", "opacity": 0.5], "translucency": ["enabled": true, "value": 0.2]],
        ],
        "supported-platforms": ["squares": "shared"],
    ]
    let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: document.appending(path: "icon.json"))
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for variant in Variant.allCases {
    try render(variant)
}
try writeIconDocument()
print("Rendered \(Variant.allCases.count) icons and AppIcon.icon to \(outputDirectory.path())")
