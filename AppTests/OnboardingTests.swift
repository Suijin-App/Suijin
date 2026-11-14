import AppKit
import Foundation
import SuijinCore
import Testing
@testable import Suijin

@MainActor
struct OnboardingTests {
    private func model() throws -> AppModel {
        AppModel(store: try SuijinStore.inMemory(),
                 dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("suijin-onboarding-\(UUID().uuidString)"))
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
        for argument in ["SuijinAppearance", "SuijinInitialSettings", "SuijinDemoPanes", "SuijinInitialTab"] {
            #expect(!OnboardingLaunchPolicy.shouldAutoShow(completed: false, environment: [:], launchArguments: [argument]))
        }
        // Unrelated arguments (AppKit's own) do not count as a scripted run.
        #expect(OnboardingLaunchPolicy.shouldAutoShow(completed: false, environment: [:],
                                                      launchArguments: ["NSDocumentRevisionsDebugMode", "ApplePersistenceIgnoreState"]))
        // The process these tests run in is itself an XCTest host.
        let model = AppModel(store: try! SuijinStore.inMemory(), dataRoot: FileManager.default.temporaryDirectory)
        model.showOnboardingIfNeeded()
        #expect(model.onboarding == nil)
    }

    @Test func theLaunchArgumentForcesTheTourAtAStep() throws {
        #expect(OnboardingLaunchPolicy.shouldAutoShow(completed: true, environment: [:], launchArguments: ["SuijinOnboarding"]))
        #expect(OnboardingLaunchPolicy.forcedStep("changes") == .changes)
        #expect(OnboardingLaunchPolicy.forcedStep("1") == .welcome)
        #expect(OnboardingLaunchPolicy.forcedStep(nil) == .welcome)

        let model = try model()
        model.showOnboardingIfNeeded(environment: [:], launchArguments: ["SuijinOnboarding": "sessions"])
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

    // MARK: Sprites and notes

    @Test func everySpritePoseStaysOnItsGrid() {
        for tint in WaterSprite.Tint.allCases {
            for mood in [LivelySprite.Mood.idle, .cheering, .sitting] {
                for time in [nil, 0.05, 0.2, 1.3, 3.39] as [Double?] {
                    let pose = LivelySprite.pose(tint: tint, mood: mood, time: time)
                    #expect(pose.lift >= 0)
                    #expect(pose.sprite.cells.count > 80)
                    for cell in pose.sprite.cells.keys {
                        #expect((0..<WaterSprite.columns).contains(cell.column))
                        #expect((0..<WaterSprite.rows).contains(cell.row))
                    }
                }
            }
        }
    }

    @Test func aStillSpriteStandsOnTheGround() {
        // Reduce Motion: no hop, both boots down.
        #expect(LivelySprite.pose(tint: .aqua, mood: .idle, time: nil).lift == 0)
        #expect(LivelySprite.pose(tint: .aqua, mood: .cheering, time: nil).lift == 0)
        #expect(LivelySprite.pose(tint: .aqua, mood: .idle, time: nil).sprite.legs == .stand)
    }

    @Test func featureStepsCarryANoteInsideTheirCapture() {
        for step in OnboardingStep.allCases {
            guard let annotation = step.annotation else {
                #expect(step.screenshot == nil)
                continue
            }
            #expect(step.screenshot != nil)
            for fraction in annotation.fractions {
                #expect((0...1).contains(fraction))
            }
            // The arrow ends in the upper half, which stays visible when a short window cuts the capture off.
            #expect(annotation.arrowEnd.y < 0.5)
        }
        #expect(Set(OnboardingStep.allCases.compactMap(\.annotation?.sprite)).count == WaterSprite.Tint.allCases.count)
    }
}
