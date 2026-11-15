import AppKit
import Foundation
import SuijinGit
import SuijinUI
import SwiftUI
import Testing
@testable import Suijin

/// The pull request summary of the inspector: which review tag it shows, and how it looks in a narrow and a wide
/// inspector.
@MainActor
struct PullRequestSummaryTests {
    private func pullRequest(_ state: PullRequest.State, review: String?, draft: Bool = false) -> PullRequest {
        PullRequest(number: 98, url: URL(string: "https://github.com/example/repo/pull/98")!,
                    title: "test: end the hosted sessions app tests leave behind", state: state, isDraft: draft,
                    reviewDecision: review)
    }

    @Test func theReviewTagShowsOnlyWhileThePullRequestIsOpen() {
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.open, review: "REVIEW_REQUIRED")) != nil)
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.open, review: "APPROVED")) != nil)
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.open, review: "CHANGES_REQUESTED")) != nil)
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.open, review: nil)) == nil)
        // Merged without a review, as an administrator can: the review is over either way.
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.merged, review: "REVIEW_REQUIRED")) == nil)
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.merged, review: "APPROVED")) == nil)
        #expect(PullRequestSummary.reviewTag(for: pullRequest(.closed, review: "CHANGES_REQUESTED")) == nil)
    }

    /// Renders the summary at a narrow and a wide inspector width, light and dark, when `SUIJIN_SCREENSHOTS` names an
    /// output folder; reviewed by eye.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
    func rendersInANarrowAndAWideInspector() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())
        let cases = [pullRequest(.merged, review: "REVIEW_REQUIRED"), pullRequest(.open, review: "REVIEW_REQUIRED"),
                     pullRequest(.open, review: "CHANGES_REQUESTED"), pullRequest(.open, review: nil, draft: true)]
        for dark in [false, true] {
            for width in [180.0, 300.0] {
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width + 32, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                    ForEach(cases, id: \.self) { pr in
                        PullRequestSummary(pr: pr)
                            .padding(10)
                            .frame(width: width, alignment: .leading)
                            .background(SuijinColor.card, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = host
                window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                defer {
                    window.contentView = nil
                    window.orderOut(nil)
                }
                try await Task.sleep(for: .milliseconds(500))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try data.write(to: output.appendingPathComponent("pull-request-summary-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
