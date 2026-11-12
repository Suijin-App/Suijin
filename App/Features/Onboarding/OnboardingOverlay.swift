import AppKit
import SevindaUI
import SwiftUI

/// The welcome tour over the whole main window, presented like Settings (same backdrop, the toolbar hidden, a fade in
/// and out), one step at a time in a centered column. Custom on purpose: a sheet is pinned to the title bar and a
/// window of its own would not belong to the app it introduces. ← and → move between steps, Return goes on, Esc
/// closes; Help › Welcome to Sevinda opens it again.
struct OnboardingOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tour: OnboardingTour

    /// The direction the step transition slides in. Changed one frame before the step itself when it flips, because
    /// the leaving step keeps the transition it had when it was last drawn.
    @State private var direction: OnboardingTour.Direction = .forward
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingMetrics(available: proxy.size)
            VStack(spacing: metrics.isCompact ? 14 : 24) {
                ZStack {
                    stepContent(tour.step, metrics: metrics)
                        .id(tour.step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                OnboardingFooter(tour: tour, perform: perform)
            }
            .frame(width: metrics.content.width, height: metrics.content.height)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background { OverlayBackdrop() }
        .onAppear {
            // The terminal behind keeps no keyboard focus while the tour is up.
            model.mainWindow?.makeFirstResponder(nil)
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("onboardingOverlay")
    }

    @ViewBuilder
    private func stepContent(_ step: OnboardingStep, metrics: OnboardingMetrics) -> some View {
        switch step {
        case .welcome: OnboardingWelcomeStep(metrics: metrics)
        case .getStarted: OnboardingGetStartedStep(metrics: metrics, perform: perform)
        default: OnboardingFeatureStep(step: step, metrics: metrics)
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = 48
        return .asymmetric(
            insertion: .offset(x: direction == .forward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: direction == .forward ? -distance : distance).combined(with: .opacity))
    }

    // MARK: Actions

    private func perform(_ command: OnboardingCommand) {
        switch command {
        case .back: move { $0.back() }
        case .advance: move { $0.advance() }
        case .show(let step): move { $0.go(to: step.index) }
        case .close: close()
        case .addWorkspace:
            close()
            AddWorkspaceFlow.run(model: model)
        case .none: break
        }
    }

    private func move(_ change: (inout OnboardingTour) -> Bool) {
        var next = tour
        guard change(&next) else { return }
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.86)
        if next.direction == direction {
            withAnimation(animation) { model.onboarding = next }
        } else {
            direction = next.direction
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                withAnimation(animation) { model.onboarding = next }
            }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { model.finishOnboarding() }
        model.focusActiveTerminalAfterClick()
    }

    // MARK: Keyboard

    /// ←, →, Return and Esc reach the tour whatever view has the keyboard, but only in the main window while no sheet
    /// or panel is in front of it (the Add Workspace panel, an alert).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let perform = perform
        let model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = OnboardingKey(keyCode: event.keyCode,
                                    hasCommandModifiers: !event.modifierFlags.intersection([.command, .option, .control]).isEmpty)
            let eventWindow = event.window.map(ObjectIdentifier.init)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let key, let tour = model.onboarding, let window = model.mainWindow,
                      eventWindow == ObjectIdentifier(window), window.attachedSheet == nil else { return false }
                perform(tour.command(for: key))
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The size of the tour's column for the space the window leaves: 1080×680 at most in a large window, shrinking with
/// it down to the window's minimum size, where the compact layout uses smaller type.
struct OnboardingMetrics: Equatable {
    let content: CGSize
    var isCompact: Bool { content.height < 560 || content.width < 860 }
    var textColumnWidth: CGFloat { isCompact ? 236 : 330 }

    init(available: CGSize) {
        let horizontal: CGFloat = available.width < 900 ? 28 : 56
        let vertical: CGFloat = available.height < 600 ? 16 : 40
        content = CGSize(width: max(min(1080, available.width - horizontal * 2), 320),
                         height: max(min(680, available.height - vertical * 2), 300))
    }
}

// MARK: Steps

/// The first step: the app icon, what Sevinda is, and its three ideas.
private struct OnboardingWelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let metrics: OnboardingMetrics
    @State private var isShown = false

    var body: some View {
        VStack(spacing: metrics.isCompact ? 12 : 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: metrics.isCompact ? 88 : 128, height: metrics.isCompact ? 88 : 128)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .scaleEffect(isShown || reduceMotion ? 1 : 0.55)
                .rotationEffect(.degrees(isShown || reduceMotion ? 0 : -12))
                .opacity(isShown ? 1 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.7, dampingFraction: 0.62).delay(0.08),
                           value: isShown)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(OnboardingStep.welcome.title)
                    .font(metrics.isCompact ? .title.bold() : .largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingStep.welcome.subtitle)
                    .font(metrics.isCompact ? .body : .title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .staggered(isShown, order: 1)
            HStack(alignment: .top, spacing: metrics.isCompact ? 10 : 14) {
                highlight("rectangle.split.3x1", "Side by Side", "Claude Code and Codex agents run together, each in its own tab or pane.", order: 2)
                highlight("arrow.triangle.branch", "One Worktree Each", "Every agent gets a branch and a folder of its own.", order: 3)
                highlight("lock.laptopcomputer", "Local Only", "No servers, no remote hosts. Your code stays on your Mac.", order: 4)
            }
            // Cards as tall as the tallest one, however their text wraps.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, metrics.isCompact ? 2 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isShown = true }
    }

    private func highlight(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, order: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(height: 28)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail)
                .font(metrics.isCompact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(metrics.isCompact ? 12 : 16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .staggered(isShown, order: order)
    }
}

/// A feature step: title, subtitle and how-to points beside a capture of the feature.
private struct OnboardingFeatureStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let step: OnboardingStep
    let metrics: OnboardingMetrics
    @State private var isShown = false

    var body: some View {
        HStack(alignment: .center, spacing: metrics.isCompact ? 20 : 28) {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 14) {
                Image(systemName: step.systemImage)
                    .font(metrics.isCompact ? .title3 : .title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .staggered(isShown, order: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title)
                        .font(metrics.isCompact ? .title3.bold() : .largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(step.subtitle)
                        .font(metrics.isCompact ? .callout : .title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .staggered(isShown, order: 1)
                VStack(alignment: .leading, spacing: metrics.isCompact ? 8 : 12) {
                    ForEach(Array(step.points.enumerated()), id: \.element.id) { offset, point in
                        OnboardingPointRow(point: point, isCompact: metrics.isCompact)
                            .staggered(isShown, order: offset + 2)
                    }
                }
                .padding(.top, 4)
            }
            .frame(width: metrics.textColumnWidth, alignment: .leading)
            if let screenshot = step.screenshot {
                OnboardingScreenshot(name: screenshot)
                    .scaleEffect(isShown || reduceMotion ? 1 : 0.94)
                    .opacity(isShown ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.6, dampingFraction: 0.82).delay(0.1),
                               value: isShown)
                    .accessibilityLabel(Text(step.screenshotDescription))
                    .accessibilityAddTraits(.isImage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isShown = true }
    }
}

/// A feature capture that always spans the column up to the tour's trailing margin (where Continue ends): it fills the
/// width, and when the column is too short for the whole capture, the bottom is cut off instead of the capture
/// shrinking away from that margin. Captures show the window's top (toolbar, sidebar) where the feature is.
private struct OnboardingScreenshot: View {
    let name: String

    var body: some View {
        GeometryReader { proxy in
            let size = NSImage(named: name)?.size ?? CGSize(width: 4, height: 3)
            let width = proxy.size.width
            let height = min(proxy.size.height, width * size.height / max(size.width, 1))
            Image(name)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// A how-to line: symbol, sentence and the shortcuts as key caps.
private struct OnboardingPointRow: View {
    let point: OnboardingPoint
    let isCompact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: point.symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(point.text)
                    .font(isCompact ? .callout : .title3)
                    .fixedSize(horizontal: false, vertical: true)
                if !point.shortcuts.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(point.shortcuts, id: \.self) { KeyCap(shortcut: $0) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A keyboard shortcut drawn as a key cap. Custom because SwiftUI has no view for showing a shortcut outside a menu.
struct KeyCap: View {
    let shortcut: String

    var body: some View {
        Text(verbatim: shortcut)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: 26)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            }
            .accessibilityLabel(Text(verbatim: ShortcutSpeech.label(for: shortcut)))
    }
}

/// The last step: add a workspace or open Settings.
private struct OnboardingGetStartedStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    let metrics: OnboardingMetrics
    let perform: (OnboardingCommand) -> Void
    @State private var isShown = false

    var body: some View {
        VStack(spacing: metrics.isCompact ? 12 : 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: metrics.isCompact ? 44 : 60))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: reduceMotion ? false : isShown)
                .staggered(isShown, order: 0)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(OnboardingStep.getStarted.title)
                    .font(metrics.isCompact ? .title.bold() : .largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingStep.getStarted.subtitle)
                    .font(metrics.isCompact ? .body : .title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .staggered(isShown, order: 1)
            HStack(spacing: 12) {
                Button { perform(.addWorkspace) } label: {
                    Label("Add Workspace…", systemImage: "plus")
                }
                .glassProminentButtonStyle()
                .help(Text("Add a git repository or a folder (Return)"))
                .accessibilityIdentifier("onboarding.addWorkspace")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        model.finishOnboarding()
                        model.settingsPage = .general
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .glassButtonStyle()
                .accessibilityIdentifier("onboarding.openSettings")
            }
            .controlSize(.extraLarge)
            .padding(.top, 6)
            .staggered(isShown, order: 2)
            Text("You can take this tour again from Help › Welcome to Sevinda.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .staggered(isShown, order: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isShown = true }
    }
}

// MARK: Footer

/// Skip on the left, the page indicator in the middle, Back and Continue (Done on the last step) on the right.
private struct OnboardingFooter: View {
    let tour: OnboardingTour
    let perform: (OnboardingCommand) -> Void

    var body: some View {
        ZStack {
            OnboardingPageIndicator(tour: tour, perform: perform)
            HStack(spacing: 10) {
                if !tour.isLast {
                    Button("Skip") { perform(.close) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(Text("Close the tour (Esc)"))
                        .accessibilityIdentifier("onboarding.skip")
                }
                Spacer()
                if !tour.isFirst {
                    Button("Back") { perform(.back) }
                        .glassButtonStyle()
                        .help(Text("Previous step (←)"))
                        .accessibilityIdentifier("onboarding.back")
                }
                if tour.isLast {
                    Button { perform(.close) } label: { Text("Done").frame(minWidth: 72) }
                        .glassButtonStyle()
                        .help(Text("Close the tour (Esc)"))
                        .accessibilityIdentifier("onboarding.done")
                } else {
                    Button { perform(.advance) } label: { Text("Continue").frame(minWidth: 72) }
                        .glassProminentButtonStyle()
                        .help(Text("Next step (→ or Return)"))
                        .accessibilityIdentifier("onboarding.continue")
                }
            }
            .controlSize(.large)
        }
    }
}

/// Dots for the steps, the current one drawn longer; clicking a dot shows that step. Custom because AppKit and
/// SwiftUI on macOS have no page control. VoiceOver reads it as one adjustable element.
private struct OnboardingPageIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tour: OnboardingTour
    let perform: (OnboardingCommand) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                let isCurrent = step == tour.step
                Capsule()
                    .fill(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: isCurrent ? 22 : 7, height: 7)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { perform(.show(step)) }
                    .help(Text(step.title))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: tour.step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tour progress"))
        .accessibilityValue(Text("Step \(tour.step.index + 1) of \(OnboardingStep.allCases.count): \(Text(tour.step.title))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: perform(tour.isLast ? .none : .advance)
            case .decrement: perform(tour.isFirst ? .none : .back)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("onboarding.pageIndicator")
    }
}

// MARK: Motion

private extension View {
    /// Fades and lifts the view in after the step appears, `order` steps of 60 ms after the first; a plain fade with
    /// Reduce Motion.
    func staggered(_ isShown: Bool, order: Int) -> some View {
        modifier(StaggeredAppearance(isShown: isShown, order: order))
    }
}

private struct StaggeredAppearance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isShown: Bool
    let order: Int

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? .easeOut(duration: 0.2)
                                    : .spring(response: 0.5, dampingFraction: 0.85).delay(0.08 + Double(order) * 0.06),
                       value: isShown)
    }
}
