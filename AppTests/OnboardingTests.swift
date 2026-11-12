import AppKit
import Foundation
import SevindaCore
import Testing
@testable import Sevinda

@MainActor
struct OnboardingTests {
    private func model() throws -> AppModel {
        AppModel(store: try MercuryStore.inMemory(),
                 dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mercury-onboarding-\(UUID().uuidString)"))
    }

    // MARK: Launch

    @Test func theFirstLaunchShowsTheTour() throws {
        let model = try model()
        model.showOnboardingIfNeeded(environment: [:], launchArguments: [:])
        #expect(model.onboarding == OnboardingTour(step: .welcome))
    }

    @Test func aCompletedTourStaysClosed() async throws {
        let model = try model()
        model.showOnboardingIfNeeded(environment: [:], launchArguments: [:])
        model.finishOnboarding()
        #expect(model.onboarding == nil)
        #expect(model.isOnboardingCompleted)

        // The flag reaches the store, so the next launch keeps the tour closed.
        for _ in 0..<50 where (try? model.store.setting(SettingKey.onboardingCompleted.rawValue)) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let relaunched = AppModel(store: model.store, dataRoot: model.dataRoot)
        await relaunched.loadSettings()
        relaunched.showOnboardingIfNeeded(environment: [:], launchArguments: [:])
        #expect(relaunched.onboarding == nil)
    }

    @Test func testsAndScriptedRunsNeverShowTheTour() {
        #expect(!OnboardingLaunchPolicy.shouldAutoShow(completed: false, environment: ["XCTestConfigurationFilePath": "/x"],
                                                       launchArguments: []))
        #expect(!OnboardingLaunchPolicy.shouldAutoShow(completed: false, environment: ["XCTestBundlePath": "/x"],
                                                       launchArguments: []))
        for argument in ["MercuryAppearance", "MercuryInitialSettings", "MercuryDemoPanes", "MercuryInitialTab"] {
            #expect(!OnboardingLaunchPolicy.shouldAutoShow(completed: false, environment: [:], launchArguments: [argument]))
        }
        // Unrelated arguments (AppKit's own) do not count as a scripted run.
        #expect(OnboardingLaunchPolicy.shouldAutoShow(completed: false, environment: [:],
                                                      launchArguments: ["NSDocumentRevisionsDebugMode", "ApplePersistenceIgnoreState"]))
        // The process these tests run in is itself an XCTest host.
        let model = AppModel(store: try! MercuryStore.inMemory(), dataRoot: FileManager.default.temporaryDirectory)
        model.showOnboardingIfNeeded()
        #expect(model.onboarding == nil)
    }

    @Test func theLaunchArgumentForcesTheTourAtAStep() throws {
        #expect(OnboardingLaunchPolicy.shouldAutoShow(completed: true, environment: [:], launchArguments: ["MercuryOnboarding"]))
        #expect(OnboardingLaunchPolicy.forcedStep("changes") == .changes)
        #expect(OnboardingLaunchPolicy.forcedStep("1") == .welcome)
        #expect(OnboardingLaunchPolicy.forcedStep(nil) == .welcome)

        let model = try model()
        model.showOnboardingIfNeeded(environment: [:], launchArguments: ["MercuryOnboarding": "sessions"])
        #expect(model.onboarding?.step == .sessions)
    }

    @Test func helpReopensTheTourOverSettings() throws {
        let model = try model()
        model.finishOnboarding()
        model.settingsPage = .stats
        model.showOnboarding()
        #expect(model.onboarding == OnboardingTour(step: .welcome))
        #expect(model.settingsPage == nil)
        // Closing it again keeps it completed.
        model.finishOnboarding()
        #expect(model.isOnboardingCompleted)
    }

    // MARK: Navigation

    @Test func navigationStaysWithinTheSteps() {
        var tour = OnboardingTour()
        #expect(tour.isFirst)
        let moved1 = tour.back()
        #expect(!moved1)
        #expect(tour.step == .welcome)

        var visited = [tour.step]
        while tour.advance() { visited.append(tour.step) }
        #expect(visited == OnboardingStep.allCases)
        #expect(tour.isLast)
        #expect(tour.direction == .forward)
        let moved2 = tour.advance()
        #expect(!moved2)

        let moved3 = tour.back()
        #expect(moved3)
        #expect(tour.step == .accounts)
        #expect(tour.direction == .backward)

        let moved4 = tour.go(to: -1)
        #expect(!moved4)
        let moved5 = tour.go(to: OnboardingStep.allCases.count)
        #expect(!moved5)
        let current = tour.step.index
        let moved6 = tour.go(to: current)
        #expect(!moved6)
        let moved7 = tour.go(to: 1)
        #expect(moved7)
        #expect(tour.step == .workspaces)
        #expect(tour.direction == .backward)
    }

    @Test func keysMapToTourCommands() {
        let first = OnboardingTour(step: .welcome)
        #expect(first.command(for: .left) == .none)
        #expect(first.command(for: .right) == .advance)
        #expect(first.command(for: .returnKey) == .advance)
        #expect(first.command(for: .escape) == .close)

        let middle = OnboardingTour(step: .changes)
        #expect(middle.command(for: .left) == .back)
        #expect(middle.command(for: .right) == .advance)

        let last = OnboardingTour(step: .getStarted)
        #expect(last.command(for: .right) == .none)
        #expect(last.command(for: .left) == .back)
        #expect(last.command(for: .returnKey) == .addWorkspace)
        #expect(last.command(for: .escape) == .close)
    }

    @Test func onlyPlainArrowsReturnAndEscapeAreTourKeys() {
        #expect(OnboardingKey(keyCode: 123, hasCommandModifiers: false) == .left)
        #expect(OnboardingKey(keyCode: 124, hasCommandModifiers: false) == .right)
        #expect(OnboardingKey(keyCode: 36, hasCommandModifiers: false) == .returnKey)
        #expect(OnboardingKey(keyCode: 76, hasCommandModifiers: false) == .returnKey)
        #expect(OnboardingKey(keyCode: 53, hasCommandModifiers: false) == .escape)
        // ⌥⌘← focuses a pane; it is not the tour's.
        #expect(OnboardingKey(keyCode: 123, hasCommandModifiers: true) == nil)
        #expect(OnboardingKey(keyCode: 0, hasCommandModifiers: false) == nil)
    }

    // MARK: Content

    @Test func featureStepsHaveShortHowToListsAndBundledScreenshots() throws {
        for step in OnboardingStep.allCases {
            switch step {
            case .welcome, .getStarted:
                #expect(step.points.isEmpty)
                #expect(step.screenshot == nil)
            default:
                #expect((2...4).contains(step.points.count), "\(step)")
                let name = try #require(step.screenshot)
                #expect(NSImage(named: name) != nil, "missing asset \(name)")
            }
        }
    }

    @Test func metricsShrinkToFitTheSmallestWindow() {
        let wide = OnboardingMetrics(available: CGSize(width: 1400, height: 880))
        #expect(wide.content == CGSize(width: 1080, height: 680))
        #expect(!wide.isCompact)
        // The window's minimum size (1000×640, title bar included): still the full layout, inside the margins.
        let small = OnboardingMetrics(available: CGSize(width: 1000, height: 640))
        #expect(small.content.width <= 1000 - 2 * 24)
        #expect(small.content.height <= 640 - 2 * 16)
        #expect(!small.isCompact)
    }

    @Test func shortcutsAreSpokenByName() {
        #expect(ShortcutSpeech.label(for: "⇧⌘O") == "Shift Command O")
        #expect(ShortcutSpeech.label(for: "⌥⌘←→") == "Option Command Left Arrow Right Arrow")
    }
}
