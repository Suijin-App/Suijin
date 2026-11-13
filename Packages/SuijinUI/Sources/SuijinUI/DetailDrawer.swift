import SwiftUI

/// Detail drawer sliding in from the right (container inspect, a user's SSH key, agent session…).
struct DetailDrawerModifier<Drawer: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: Text
    let drawer: Drawer

    func body(content: Content) -> some View {
        content.inspector(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    title.font(.headline)
                    Spacer()
                    Button { isPresented = false } label: {
                        Label { Text("Close", bundle: .module) } icon: { Image(systemName: "xmark") }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("drawer.close")
                }
                .padding(SuijinSpacing.m)
                Divider()
                ScrollView { drawer.padding(SuijinSpacing.m).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .inspectorColumnWidth(min: 320, ideal: 440, max: 600)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drawer")
        }
    }
}

extension View {
    /// Attaches a right-hand detail drawer to the view.
    public func detailDrawer<Drawer: View>(isPresented: Binding<Bool>, title: Text, @ViewBuilder content: () -> Drawer) -> some View {
        modifier(DetailDrawerModifier(isPresented: isPresented, title: title, drawer: content()))
    }
}
