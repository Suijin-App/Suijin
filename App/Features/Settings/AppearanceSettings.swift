import SuijinUI
import SwiftUI

/// Settings → General → Appearance: System, Light and Dark as window thumbnails, like System Settings → Appearance.
/// A custom view because no native control shows a picture per choice; a segmented `Picker` would only show text.
struct AppearancePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: SuijinSpacing.xl) {
            ForEach(AppAppearance.allCases) { appearance in
                SelectableCard(isSelected: model.appearance == appearance, title: appearance.title) {
                    model.setAppearance(appearance)
                } content: {
                    WindowThumbnail(appearance: appearance)
                        .frame(width: 92, height: 60)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SuijinSpacing.xs)
    }
}

extension AppAppearance {
    var title: LocalizedStringKey {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// A thumbnail with a title below; the selected one gets an accent ring and a bold title. Used for appearance and
/// terminal theme choices.
struct SelectableCard<Content: View>: View {
    let isSelected: Bool
    let title: Text
    let action: () -> Void
    @ViewBuilder let content: Content

    init(isSelected: Bool, title: LocalizedStringKey, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(isSelected: isSelected, title: Text(title), action: action, content: content)
    }

    init(isSelected: Bool, title: Text, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: SuijinSpacing.s) {
                content
                    .clipShape(.rect(cornerRadius: SuijinRadius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: SuijinRadius.control)
                            .strokeBorder(.separator, lineWidth: 1)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: SuijinRadius.control + 3)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .opacity(isSelected ? 1 : 0)
                    }
                title
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature window in light, dark, or (for Automatic) split light and dark.
private struct WindowThumbnail: View {
    let appearance: AppAppearance

    var body: some View {
        switch appearance {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            MiniWindow(dark: false)
                .overlay {
                    MiniWindow(dark: true)
                        .mask(alignment: .trailing) {
                            GeometryReader { proxy in
                                Rectangle().frame(width: proxy.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                }
        }
    }
}

/// Fixed colors on purpose: the thumbnail shows each appearance regardless of the one Settings is drawn in.
private struct MiniWindow: View {
    let dark: Bool

    private var desktop: Color { dark ? Color(white: 0.16) : Color(red: 0.80, green: 0.86, blue: 0.95) }
    private var window: Color { dark ? Color(white: 0.20) : Color(white: 0.99) }
    private var sidebar: Color { dark ? Color(white: 0.26) : Color(white: 0.92) }
    private var line: Color { dark ? Color(white: 0.40) : Color(white: 0.80) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            desktop
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2.5) {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                    }
                    .frame(height: 5)
                    Capsule().fill(Color.accentColor).frame(width: 18, height: 4)
                    Capsule().fill(line).frame(width: 14, height: 3)
                    Capsule().fill(line).frame(width: 16, height: 3)
                }
                .padding(5)
                .frame(width: 32)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(sidebar)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(line).frame(width: 26, height: 4)
                    Capsule().fill(line.opacity(0.7)).frame(width: 34, height: 3)
                    Capsule().fill(line.opacity(0.7)).frame(width: 22, height: 3)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(window)
            }
            .clipShape(.rect(cornerRadius: 4))
            .padding(.top, 10)
            .padding(.leading, 12)
            .padding([.bottom, .trailing], -6)
        }
        .accessibilityHidden(true)
    }
}
