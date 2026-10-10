import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Everything drawn on the info screen (Neo). Frames that compare equal aren't sent again.
enum ScreenFrame: Equatable {
    /// Static text: a big title over a grey subtitle.
    case message(title: String, subtitle: String)
    /// A sound's waveform (column peaks, 0…1) with the first `played` columns highlighted.
    case playing(title: String, info: String, peaks: [Float], played: Int)
    /// Recent input levels, oldest first.
    case input(title: String, info: String, warning: Bool, levels: [InputLevel])

    /// Heights are 0…1 of the graph, in steps of a pixel or so, so silence doesn't redraw.
    struct InputLevel: Equatable {
        /// The input as it arrives from the device.
        var raw: Float
        /// What goes out to the call (after noise removal).
        var sent: Float
        var clipped: Bool
    }
}

enum KeyRenderer {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let activeColor = CGColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func color(hex: String?) -> CGColor {
        guard var hex, hex.hasPrefix("#") else { return CGColor(srgbRed: 0.2, green: 0.2, blue: 0.22, alpha: 1) }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return CGColor(gray: 0.2, alpha: 1) }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    static func key(size: Int, label: String?, image: CGImage?, background: CGColor,
                    active: Bool, warning: Bool) -> CGImage {
        draw(width: size, height: size) { ctx in
            let s = CGFloat(size)
            let bounds = CGRect(x: 0, y: 0, width: s, height: s)
            ctx.setFillColor(image == nil ? background : CGColor(gray: 0, alpha: 1))
            ctx.fill(bounds)

            if let image {
                let scale = max(s / CGFloat(image.width), s / CGFloat(image.height))
                let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
                if let label, !label.isEmpty {
                    let band = s * 0.3
                    ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
                    ctx.fill(CGRect(x: 0, y: 0, width: s, height: band))
                    text(label, in: CGRect(x: 4, y: 0, width: s - 8, height: band), maxSize: s * 0.17, ctx: ctx)
                }
            } else if let label, !label.isEmpty {
                text(label, in: bounds.insetBy(dx: s * 0.08, dy: s * 0.08), maxSize: s * 0.28, ctx: ctx)
            }

            if warning {
                text("⚠︎", in: CGRect(x: s * 0.62, y: s * 0.62, width: s * 0.36, height: s * 0.36),
                     maxSize: s * 0.28, color: .systemYellow, ctx: ctx)
            }
            if active {
                let inset = s * 0.04
                ctx.setStrokeColor(activeColor)
                ctx.setLineWidth(s * 0.07)
                ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                   cornerWidth: s * 0.12, cornerHeight: s * 0.12, transform: nil))
                ctx.strokePath()
            }
        }
    }

    // MARK: Info screen

    /// Margin around the info screen's graph; the graph has one column per pixel in between.
    private static let screenMargin = 4

    /// Columns of a waveform drawn on a screen this wide.
    static func waveformColumns(screenWidth: Int) -> Int { screenWidth - 2 * screenMargin }

    /// Input level history bars: 3 px wide with a 1 px gap.
    static func levelBars(screenWidth: Int) -> Int { waveformColumns(screenWidth: screenWidth) / 4 }

    static func screen(_ frame: ScreenFrame, width: Int, height: Int) -> CGImage {
        draw(width: width, height: height) { ctx in
            let w = CGFloat(width), h = CGFloat(height)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let margin = CGFloat(screenMargin)
            // Header on top, graph below it.
            let header = CGRect(x: margin + 2, y: h - 18, width: w - 2 * margin - 4, height: 16)
            let graph = CGRect(x: margin, y: 3, width: w - 2 * margin, height: h - 23)
            let mid = graph.midY.rounded()

            switch frame {
            case let .message(title, subtitle):
                text(title, in: CGRect(x: 6, y: h * 0.42, width: w - 12, height: h * 0.55),
                     maxSize: h * 0.4, singleLine: true, ctx: ctx)
                text(subtitle, in: CGRect(x: 6, y: 2, width: w - 12, height: h * 0.4),
                     maxSize: h * 0.26, weight: .regular, color: .lightGray, singleLine: true, ctx: ctx)

            case let .playing(title, info, peaks, played):
                headerLine(title, info: info, infoColor: .lightGray, in: header)
                // Mirrored waveform: played part green, the rest grey, white playhead.
                for (x, peak) in peaks.enumerated() {
                    let half = max(0.5, CGFloat(peak) * graph.height / 2).rounded(.up)
                    ctx.setFillColor(x < played ? activeColor : CGColor(gray: 0.38, alpha: 1))
                    ctx.fill(CGRect(x: graph.minX + CGFloat(x), y: mid - half, width: 1, height: 2 * half))
                }
                if played > 0 && played < peaks.count {
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(CGRect(x: graph.minX + CGFloat(played), y: graph.minY, width: 1, height: graph.height))
                }

            case let .input(title, info, warning, levels):
                headerLine(title, info: info, infoColor: warning ? .systemOrange : .lightGray, in: header)
                // Newest on the right. Raw input in grey behind what's sent, so noise removal shows.
                let start = graph.maxX - CGFloat(levels.count * 4) + 1
                for (i, level) in levels.enumerated() {
                    let x = start + CGFloat(i * 4)
                    let raw = max(0.5, CGFloat(level.raw) * graph.height / 2).rounded(.up)
                    ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
                    ctx.fill(CGRect(x: x, y: mid - raw, width: 3, height: 2 * raw))
                    let sent = (CGFloat(level.sent) * graph.height / 2).rounded(.up)
                    guard sent > 0 else { continue }
                    ctx.setFillColor(level.clipped ? clipColor : level.sent > 0.9 ? loudColor : activeColor)
                    ctx.fill(CGRect(x: x, y: mid - sent, width: 3, height: 2 * sent))
                }
            }
        }
    }

    private static let loudColor = CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1)
    private static let clipColor = CGColor(srgbRed: 1, green: 0.25, blue: 0.2, alpha: 1)

    /// Bold title on the left, `info` on the right; the title gives way when space runs out.
    private static func headerLine(_ title: String, info: String, infoColor: NSColor, in rect: CGRect) {
        let infoAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: infoColor]
        let infoWidth = info.isEmpty ? 0 : ceil((info as NSString).size(withAttributes: infoAttributes).width)
        (info as NSString).draw(at: CGPoint(x: rect.maxX - infoWidth, y: rect.minY), withAttributes: infoAttributes)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width - infoWidth - (infoWidth > 0 ? 8 : 0),
                               height: rect.height)
        (title as NSString).draw(with: titleRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    }

    /// JPEG for the device. Stream Decks mount their panels upside down, so rotate 180°.
    static func jpeg(_ image: CGImage, rotate: Bool = true, quality: CGFloat = 0.92) -> Data {
        let output = rotate ? draw(width: image.width, height: image.height) { ctx in
            ctx.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
            ctx.rotate(by: .pi)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        } : image
        return encode(output, type: .jpeg, quality: quality)
    }

    static func png(_ image: CGImage) -> Data {
        encode(image, type: .png, quality: 1)
    }

    // MARK: Helpers

    private static func encode(_ image: CGImage, type: UTType, quality: CGFloat) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// Draws text centred in `rect`, shrinking the font until it fits without breaking words.
    private static func text(_ string: String, in rect: CGRect, maxSize: CGFloat,
                             weight: NSFont.Weight = .bold, color: NSColor = .white,
                             singleLine: Bool = false, ctx: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero

        var size = maxSize
        var attributes: [NSAttributedString.Key: Any] = [:]
        var bounds = CGRect.zero
        let words = string.split(whereSeparator: \.isWhitespace)
        repeat {
            attributes = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                          .foregroundColor: color, .paragraphStyle: paragraph, .shadow: shadow]
            bounds = (string as NSString).boundingRect(
                with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: singleLine ? [] : [.usesLineFragmentOrigin], attributes: attributes)
            let longestWord = words.map { (String($0) as NSString).size(withAttributes: attributes).width }.max() ?? 0
            if bounds.height <= rect.height && longestWord <= rect.width { break }
            size -= 1
        } while size > 8

        let height = min(bounds.height, rect.height)
        let target = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (string as NSString).draw(with: target, options: singleLine ? [.truncatesLastVisibleLine] : [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: attributes)
    }
}
