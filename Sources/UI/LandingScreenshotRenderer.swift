import AppKit

/// Produces the public landing-page image from the live popover view. Caching
/// the already-laid-out view into a 4× bitmap preserves SwiftUI's native
/// controls and symbols while avoiding the 1× display density of GitHub-hosted
/// macOS runners without interpolating app pixels.
@MainActor
enum LandingScreenshotRenderer {
    static let pointSize = CGSize(width: 420, height: 560)

    enum RenderError: Error {
        case unexpectedViewSize(CGSize)
        case bitmapUnavailable
        case pngUnavailable
    }

    static func write(view: NSView, to outputURL: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        guard view.bounds.size == pointSize else {
            throw RenderError.unexpectedViewSize(view.bounds.size)
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1680,
            pixelsHigh: 2240,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.bitmapUnavailable
        }
        bitmap.size = pointSize
        view.cacheDisplay(in: view.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngUnavailable
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: outputURL, options: .atomic)
    }
}
