import AppKit

public enum Icons {
    /// PNG-backed ICNS is supported on all target macOS releases; no Xcode/iconutil is needed at runtime.
    public static func writeCloneIcon(source: URL, destination: URL) throws {
        let original = NSWorkspace.shared.icon(forFile: source.path)
        try writeICNS(to: destination) { rect in
            original.draw(in: rect)
            let d = rect.width * 0.38
            let badge = NSRect(x: rect.maxX - d - rect.width * 0.035,
                               y: rect.height * 0.035, width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -rect.width * 0.012, dy: -rect.width * 0.012)).fill()
            NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.94, alpha: 1).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: d * 0.67, weight: .bold),
                .foregroundColor: NSColor.white, .paragraphStyle: style
            ]
            let label = NSAttributedString(string: "2", attributes: attributes)
            let height = label.size().height
            label.draw(in: NSRect(x: badge.minX, y: badge.midY - height / 2,
                                 width: d, height: height))
        }
    }

    public static func writeToolIcon(to url: URL) throws {
        try writeICNS(to: url) { rect in
            NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.23, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.06, dy: rect.width * 0.06),
                         xRadius: rect.width * 0.21, yRadius: rect.width * 0.21).fill()
            let a = NSRect(x: rect.width * 0.23, y: rect.height * 0.34, width: rect.width * 0.44, height: rect.height * 0.44)
            NSColor(calibratedRed: 0.32, green: 0.79, blue: 0.71, alpha: 1).setFill()
            NSBezierPath(roundedRect: a, xRadius: rect.width * 0.10, yRadius: rect.width * 0.10).fill()
            let b = a.offsetBy(dx: rect.width * 0.13, dy: -rect.height * 0.15)
            NSColor(calibratedRed: 0.20, green: 0.44, blue: 0.98, alpha: 1).setFill()
            NSBezierPath(roundedRect: b, xRadius: rect.width * 0.10, yRadius: rect.width * 0.10).fill()
            let text = NSAttributedString(string: "2", attributes: [.font: NSFont.systemFont(ofSize: rect.width * 0.31, weight: .semibold), .foregroundColor: NSColor.white])
            text.draw(at: NSPoint(x: b.midX - text.size().width / 2, y: b.midY - text.size().height / 2))
        }
    }

    private static func writeICNS(to url: URL, draw: (NSRect) -> Void) throws {
        var chunks = Data()
        for (size, type) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { throw DualError.message("无法生成副本图标。") }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            draw(NSRect(x: 0, y: 0, width: size, height: size))
            context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { throw DualError.message("无法保存副本图标。") }
            chunks.append(Data(type.utf8)); chunks.append(bigEndian: UInt32(png.count + 8)); chunks.append(png)
        }
        var result = Data("icns".utf8); result.append(bigEndian: UInt32(chunks.count + 8)); result.append(chunks)
        try result.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func append(bigEndian number: UInt32) {
        var value = number.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
