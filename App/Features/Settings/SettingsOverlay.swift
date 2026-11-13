import SuijinUI
import SwiftUI

/// Settings over the whole main window, like an onboarding screen rather than a separate window or a sheet: a calm
/// backdrop, a header with Back, the pages as a segmented tab bar, and the selected page in one centered column.
/// Back, Esc, ⌘W or ⌘, again return to the app. Custom on purpose: SwiftUI's `Settings` scene is always a window of
/// its own.
struct SettingsOverlay: View {
    @Environment(AppModel.self) private var model
    let page: SettingsPage

    var body: some View {
        VStack(spacing: SuijinSpacing.m) {
            ZStack {
                HStack {
                    Button { close() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .glassButtonStyle()
                    .controlSize(.large)
                    .keyboardShortcut(ShortcutCatalog.closeSettings.shortcut)
                    .help(Text("Back to Suijin (Esc)"))
                    .accessibilityIdentifier("settings.back")
                    Spacer()
                }
                // Titles and symbols while they fit clear of the Back button, symbols only in a narrow window.
                ViewThatFits(in: .horizontal) {
                    pagePicker.fixedSize()
                    pagePicker.labelStyle(.iconOnly).fixedSize()
                }
                .padding(.horizontal, 104)
            }
            // Clear of the window buttons, which stay in the transparent title bar.
            .padding(.leading, 78)
            .padding(.trailing, SuijinSpacing.xl)
            .padding(.top, 10)
            page.content
                // The grouped forms sit on the backdrop instead of their own opaque page.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(page)
        }
        .background { OverlayBackdrop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsOverlay")
    }

    private var pagePicker: some View {
        Picker("Settings page", selection: Binding(get: { page }, set: { model.settingsPage = $0 })) {
            ForEach(SettingsPage.allCases) { page in
                Label(page.title, systemImage: page.systemImage)
                    .help(Text(page.title))
                    .tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { model.settingsPage = nil }
    }
}

/// The window background with a soft glow of the accent color from the top, behind Settings and the welcome tour.
struct OverlayBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if contrast != .increased {
                RadialGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.07), .clear],
                               center: .top, startRadius: 0, endRadius: 560)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
