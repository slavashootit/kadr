import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum GIFExporter {
    /// Converts a video to a looping GIF next to it (or in the captures folder).
    static func export(video: URL, fps: Int? = nil, maxWidth: Int? = nil) async throws -> URL {
        let fps = fps ?? Prefs.gifFPS
        let maxWidth = CGFloat(maxWidth ?? Prefs.gifMaxWidth)
        let out = video.deletingPathExtension().appendingPathExtension("gif")

        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw KadrError.nothingToDo("Порожнє відео") }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let tol = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)

        let count = max(1, Int(duration * Double(fps)))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw KadrError.writeFailed
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 1.0 / Double(fps),
                kCGImagePropertyGIFUnclampedDelayTime as String: 1.0 / Double(fps),
            ],
        ] as CFDictionary

        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600)
            let (img, _) = try await gen.image(at: t)
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw KadrError.writeFailed }
        return out
    }
}
