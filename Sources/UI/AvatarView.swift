import SwiftUI

/// Circular avatar with an SF Symbol fallback while loading or when there is
/// no image (upstream AvatarWithFallback). Used by notification rows and the
/// account/repository headers.
struct AvatarView: View {
    let url: URL?
    let size: CGFloat
    var fallbackSymbol = "person.crop.circle"

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable()
        } placeholder: {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
