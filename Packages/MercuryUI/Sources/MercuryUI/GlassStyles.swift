import AppKit
import SwiftUI

extension View {
    /// The system Liquid Glass prominent button on macOS 26, the bordered prominent one before.
    @ViewBuilder public func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// The system Liquid Glass button on macOS 26, the bordered one before.
    @ViewBuilder public func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Real Liquid Glass behind a floating element (status badge, toast) on macOS 26. Earlier systems get a
    /// plain opaque control background in the same shape, never an imitation of glass.
    ///
    /// `tint` colors the glass (a prominent round button) and `interactive` makes it react to the pointer; earlier
    /// systems ignore both.
    @ViewBuilder public func floatingGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = .regular
            let tinted = tint.map { base.tint($0) } ?? base
            glassEffect(interactive ? tinted.interactive() : tinted, in: shape)
        } else {
            background(Color(nsColor: .controlBackgroundColor), in: shape)
        }
    }
}

extension View {
    /// A round Liquid Glass icon button on macOS 26 (accessory buttons next to in-content tabs); a
    /// borderless icon button before, like the toolbar-less accessories of earlier systems.
    @ViewBuilder public func glassIconButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.borderless)
        }
    }
}

/// Lets neighbouring glass elements render and blend as one group (`GlassEffectContainer`) on macOS 26;
/// earlier systems show the content unchanged.
public struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
