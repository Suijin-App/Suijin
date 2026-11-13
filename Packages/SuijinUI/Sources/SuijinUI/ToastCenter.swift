import Observation
import SwiftUI

/// Short notification at the bottom of the window (`Đã copy lệnh`, `Đã kết nối prod-api-01`…).
@MainActor
@Observable
public final class ToastCenter {
    public struct Toast: Identifiable, Equatable {
        public let id = UUID()
        public let message: String
    }

    public private(set) var toasts: [Toast] = []
    private let lifetime: Duration

    public init(lifetime: Duration = .seconds(2.6)) {
        self.lifetime = lifetime
    }

    public func show(_ message: String) {
        let toast = Toast(message: message)
        toasts.append(toast)
        Task { [weak self, lifetime] in
            try? await Task.sleep(for: lifetime)
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }
}

/// Overlay that displays toasts; placed once at the window root. Custom on purpose: macOS has no in-window
/// transient notification (user notifications go to Notification Center, which is wrong for `Đã copy lệnh`).
/// The capsule floats over the content, so it uses real Liquid Glass on macOS 26.
public struct ToastOverlay: View {
    let center: ToastCenter

    public init(center: ToastCenter) {
        self.center = center
    }

    public var body: some View {
        VStack(spacing: 6) {
            ForEach(center.toasts) { toast in
                Text(toast.message)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingGlass(in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.easeOut(duration: 0.15), value: center.toasts)
        .padding(.bottom, 40)
        .allowsHitTesting(false)
    }
}
