import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Unified image preparation for anything that enters a model's context.
///
/// [GAP-REVIEW IMG-1/2/3/4] Before this type existed, every image entry
/// point (fresh send, queued send, history reload, each provider's wire
/// conversion) prepared payloads its own way — or not at all:
///
///   * HEIC/PNG bytes went out labelled `image/jpeg` because the mime was
///     derived from the file extension or a "did the byte count change"
///     guess instead of the bytes themselves (IMG-1).
///   * The per-image 5 MB budget was a warning, not a cap — oversize
///     payloads were "sent anyway", and once persisted to history they
///     re-failed the request on every subsequent turn, permanently
///     poisoning the session (IMG-2).
///   * The queued-send path had no byte budget at all, and history reload
///     passed stored bytes through untouched (IMG-4 / IMG-2a).
///   * Gemini/Antigravity exits had no payload safeguards, and
///     Anthropic/Gemini/Antigravity had no vision-capability gate —
///     images went to text-only models raw (IMG-3).
///
/// The rule now, applied at every entry point via this one type:
///
///   1. The mime label is ALWAYS derived from the payload's magic bytes
///      (sniffing), never from a filename or a stored string.
///   2. A payload passes through untouched ONLY when its sniffed format
///      is in the caller's accepted set, its long edge is within
///      `contextMaxLongEdge`, and it fits the byte budget. This preserves
///      transparent PNGs and animated GIFs whenever they fit (they would
///      lose alpha/animation in a JPEG re-encode).
///   3. Anything else is re-encoded to JPEG at or under the caps (label
///      `image/jpeg` then genuinely describes the bytes). Animated or
///      transparent images that DON'T fit are flattened to their first
///      frame — a deliberate trade: a flattened image beats a rejected
///      request.
///   4. If the payload cannot be made compliant (undecodable, or still
///      over budget at the bottom of the quality ladder) the result is
///      `nil` and the CALLER degrades that image to a text placeholder.
///      Non-compliant bytes never leave the process.
enum ImagePayloadPrep {

    /// Long-edge cap for images entering model context. 1536 matches the
    /// scale mainstream vision APIs use internally (Anthropic's standard
    /// tier resizes to ≤1568px anyway), keeps small UI text legible, and
    /// bounds per-image tokens.
    static let contextMaxLongEdge: CGFloat = 1536

    /// Per-image byte budget (base64 inflates ~4/3×, so 5 MB of bytes is
    /// ~6.7 MB on the wire — comfortably inside every provider's limit).
    static let contextMaxBytes: Int = 5 * 1024 * 1024

    /// Formats Anthropic / OpenAI accept for image input.
    static let standardPassthroughFormats: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    /// Gemini additionally accepts HEIC/HEIF natively.
    static let geminiPassthroughFormats: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
        "image/heic", "image/heif",
    ]

    // MARK: - Format sniffing

    /// Detect the real image format from magic bytes. Returns nil when the
    /// leading bytes match no known image signature.
    static func sniffMimeType(_ data: Data) -> String? {
        guard data.count >= 3 else { return nil }
        let b = [UInt8](data.prefix(16))
        // JPEG: FF D8 FF
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return "image/jpeg" }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if data.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
        // GIF: "GIF8"
        if data.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        // WebP: "RIFF" .... "WEBP"
        if data.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        // ISO-BMFF (HEIC/HEIF/AVIF): "ftyp" box + brand
        if data.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            switch brand {
            case "heic", "heix", "hevc", "heim", "heis", "hevm", "hevs":
                return "image/heic"
            case "mif1", "msf1", "heif":
                return "image/heif"
            case "avif", "avis":
                return "image/avif"
            default:
                return nil
            }
        }
        // TIFF: 49 49 2A 00 / 4D 4D 00 2A
        if data.count >= 4,
           (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return "image/tiff" }
        // BMP: "BM"
        if data.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        return nil
    }

    // MARK: - Header inspection (no full decode)

    /// Pixel dimensions from the image header via ImageIO properties.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return CGSize(width: w.doubleValue, height: h.doubleValue)
    }

    /// Number of frames (1 for still images; >1 for animated GIF/WebP).
    static func frameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    // MARK: - The unified preparation

    /// Prepare one image payload for model context under the rules in the
    /// type docstring. Returns the (possibly original) bytes plus the mime
    /// that truthfully describes them, or nil when the image cannot be
    /// made compliant — the caller MUST degrade to a text placeholder on
    /// nil rather than send the raw bytes.
    static func preparedForContext(
        _ data: Data,
        maxBytes: Int = contextMaxBytes,
        maxLongEdge: CGFloat = contextMaxLongEdge,
        passthroughFormats: Set<String> = standardPassthroughFormats
    ) -> (data: Data, mimeType: String)? {
        guard !data.isEmpty else { return nil }
        if let sniffed = sniffMimeType(data),
           passthroughFormats.contains(sniffed),
           data.count <= maxBytes,
           let size = pixelSize(data),
           max(size.width, size.height) <= maxLongEdge {
            return (data, sniffed)
        }
        guard let jpeg = reencodedJPEG(data, maxBytes: maxBytes, maxLongEdge: maxLongEdge) else {
            return nil
        }
        return (jpeg, "image/jpeg")
    }

    /// Re-encode to JPEG, walking a (long edge × quality) ladder until the
    /// output fits `maxBytes`. Returns nil when even the smallest useful
    /// rung stays over budget or the source cannot be decoded at all.
    private static func reencodedJPEG(_ data: Data, maxBytes: Int, maxLongEdge: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var edges: [CGFloat] = [maxLongEdge]
        for e: CGFloat in [1536, 1280, 1024, 800, 640, 480] where e < maxLongEdge {
            edges.append(e)
        }
        let qualities: [CGFloat] = [0.82, 0.74, 0.66, 0.58, 0.50]
        for edge in edges {
            guard let image = thumbnailImage(source, maxPixel: edge) else { continue }
            for q in qualities {
                guard let encoded = jpegData(image, quality: q) else { continue }
                if encoded.count <= maxBytes { return encoded }
            }
        }
        return nil
    }

    /// Downscaled image via ImageIO thumbnails (low-memory, EXIF-aware).
    /// Falls back to a manual CGContext scale when thumbnail creation is
    /// unavailable for the source format.
    private static func thumbnailImage(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumb
        }
        guard let full = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { return nil }
        let w = CGFloat(full.width), h = CGFloat(full.height)
        let longest = max(w, h)
        guard longest > maxPixel else { return full }
        let scale = maxPixel / longest
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return full }
        // Flatten transparency onto white (JPEG has no alpha channel).
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? full
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Message-level image transforms

extension AgentMessage {

    /// [IMG-3] Vision-capability gate, applied at the top of each
    /// provider's message conversion (the assembly layer): when the model
    /// being addressed cannot accept image input, `.imageData` parts are
    /// replaced with the SAME text placeholder the OpenAI path has always
    /// used (`VisionGroupResolver.attachmentPlaceholder` — it points the
    /// model at `read_image` when a Vision Group is configured), and tool
    /// results keep their text content with the image dropped. Before this
    /// gate, Anthropic/Gemini/Antigravity sent the images raw and let the
    /// provider 400 (or silently mishandle) them.
    static func gatedForVisionCapability(
        _ messages: [AgentMessage],
        supportsImageInput: Bool
    ) -> [AgentMessage] {
        guard !supportsImageInput else { return messages }
        var changed = false
        let mapped = messages.map { msg -> AgentMessage in
            var copy = msg
            copy.parts = msg.parts.map { part in
                switch part {
                case .imageData(_, _, let linuxPath):
                    changed = true
                    return .text(VisionGroupResolver.attachmentPlaceholder(linuxPath: linuxPath))
                case .toolResult(let id, let name, let content, let isError,
                                 let imageData, _, let pageURL, let imageLinuxPath)
                    where imageData != nil:
                    changed = true
                    return .toolResult(
                        id: id, name: name, content: content, isError: isError,
                        imageData: nil, imageMimeType: nil,
                        pageURL: pageURL, imageLinuxPath: imageLinuxPath
                    )
                default:
                    return part
                }
            }
            return copy
        }
        return changed ? mapped : messages
    }

    /// True when any part carries image bytes (user attachment or tool result).
    static func containsImagePayload(_ messages: [AgentMessage]) -> Bool {
        for msg in messages {
            for part in msg.parts {
                switch part {
                case .imageData:
                    return true
                case .toolResult(_, _, _, _, let imageData, _, _, _) where imageData != nil:
                    return true
                default:
                    continue
                }
            }
        }
        return false
    }

    /// [IMG-2b] Strip every image payload, replacing attachments with a
    /// text placeholder that keeps the on-disk path (so the model can
    /// re-fetch via `read_image`) and dropping tool-result images while
    /// keeping their text output. Used by the one-shot self-heal retry:
    /// when a provider rejects a request over an image and the whole group
    /// would otherwise burn through its members re-sending the same bytes.
    static func replacingImagesWithPlaceholders(_ messages: [AgentMessage]) -> [AgentMessage] {
        messages.map { msg in
            var copy = msg
            copy.parts = msg.parts.map { part in
                switch part {
                case .imageData(_, _, let linuxPath):
                    if let path = linuxPath, !path.isEmpty {
                        return .text("[image omitted: the provider rejected the image payload. "
                            + "The original file is at \(path) — use read_image to view it.]")
                    }
                    return .text("[image omitted: the provider rejected the image payload.]")
                case .toolResult(let id, let name, let content, let isError,
                                 let imageData, _, let pageURL, let imageLinuxPath)
                    where imageData != nil:
                    return .toolResult(
                        id: id, name: name, content: content, isError: isError,
                        imageData: nil, imageMimeType: nil,
                        pageURL: pageURL, imageLinuxPath: imageLinuxPath
                    )
                default:
                    return part
                }
            }
            return copy
        }
    }
}
