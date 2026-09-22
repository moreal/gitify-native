import AppKit
import SwiftUI

/// Produces the public landing-page image by asking SwiftUI to redraw the
/// popover at 4×. This does not depend on the CI runner's 1× window backing
/// scale, so text and symbols contain real high-density pixels.
@MainActor
enum LandingScreenshotRenderer {
    static let pointSize = CGSize(width: 420, height: 560)

    enum RenderError: Error {
        case imageUnavailable
        case unexpectedPixelSize(width: Int, height: Int)
        case pngUnavailable
    }

    static func write(
        settings: SettingsStore,
        accountsStore: AccountsStore,
        notificationsStore: NotificationsStore,
        updateChecker: UpdateChecker,
        to outputURL: URL
    ) throws {
        let content = PopoverRootView()
            .environmentObject(settings)
            .environmentObject(accountsStore)
            .environmentObject(notificationsStore)
            .environmentObject(notificationsStore.filters)
            .environmentObject(updateChecker)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(pointSize)
        renderer.scale = 4
        renderer.isOpaque = true

        guard let image = renderer.cgImage else {
            throw RenderError.imageUnavailable
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard bitmap.pixelsWide == 1680, bitmap.pixelsHigh == 2240 else {
            throw RenderError.unexpectedPixelSize(
                width: bitmap.pixelsWide,
                height: bitmap.pixelsHigh
            )
        }
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
