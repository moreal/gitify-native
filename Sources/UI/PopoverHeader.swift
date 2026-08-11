import SwiftUI

/// Back-navigation chrome shared by the popover's pushed routes
/// (Settings, Filters, Add account): chevron, title, optional trailing
/// accessory, and the divider separating the header from the content.
struct PopoverHeader<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    let trailing: Trailing

    init(
        _ title: String,
        onBack: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text(title)
                    .font(.headline)
                Spacer()
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
        }
    }
}

extension PopoverHeader where Trailing == EmptyView {
    init(_ title: String, onBack: @escaping () -> Void) {
        self.init(title, onBack: onBack) { EmptyView() }
    }
}
