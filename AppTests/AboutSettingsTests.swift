import Foundation
import Testing
@testable import Suijin

struct AboutSettingsTests {
    @Test func aboutIsTheLastSettingsPage() {
        #expect(SettingsPage.allCases.last == .about)
        #expect(SettingsPage(rawValue: "about") == .about)
    }

    @Test func identityComesFromTheBundleInfo() {
        let identity = AppIdentity(info: [
            "CFBundleDisplayName": "Suijin", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45",
            "NSHumanReadableCopyright": "© 2026 Tekmium Solutions",
        ])
        #expect(identity == AppIdentity(info: [
            "CFBundleName": "Suijin", "CFBundleShortVersionString": " 1.2.3 ", "CFBundleVersion": "45",
            "NSHumanReadableCopyright": "© 2026 Tekmium Solutions",
        ]))
        #expect(identity.version == "1.2.3")
        #expect(identity.build == "45")
        #expect(identity.copyright == "© 2026 Tekmium Solutions")
    }

    @Test func missingBundleValuesFallBackInsteadOfShowingBlanks() {
        let identity = AppIdentity(info: ["CFBundleShortVersionString": "", "NSHumanReadableCopyright": "  "])
        #expect(identity.name == "Suijin")
        #expect(identity.version == "—")
        #expect(identity.build == "—")
        #expect(identity.copyright == nil)
    }

    @Test func theAppBundleCarriesTheCopyrightLine() {
        #expect(AppIdentity.current.copyright == "© 2026 Tekmium Solutions")
    }

    @Test func supportMailLinkAcceptsOnlyPlainAddresses() {
        #expect(AboutLinks.mailURL("help@example.com")?.absoluteString == "mailto:help@example.com")
        #expect(AboutLinks.mailURL(" help@example.com ")?.absoluteString == "mailto:help@example.com")
        #expect(AboutLinks.mailURL(nil) == nil)
        #expect(AboutLinks.mailURL("") == nil)
        #expect(AboutLinks.mailURL("not an address") == nil)
        #expect(AboutLinks.mailURL("a@b.com?subject=x") == nil)
        #expect(AboutLinks.mailURL("a@b@c.com") == nil)
    }

    @Test func legalDocumentsHaveTitledSectionsWithText() {
        for kind in LegalDocument.Kind.allCases {
            let document = LegalDocument.document(kind)
            #expect(document.kind == kind)
            #expect(!document.title.isEmpty)
            #expect(document.sections.count > 3)
            #expect(document.sections.dropFirst().allSatisfy { $0.heading?.isEmpty == false })
            for section in document.sections {
                #expect(!section.blocks.isEmpty)
                for block in section.blocks {
                    switch block {
                    case .paragraph(let text): #expect(!text.characters.isEmpty)
                    case .bullets(let items): #expect(!items.isEmpty && items.allSatisfy { !$0.characters.isEmpty })
                    }
                }
            }
        }
    }

    @Test func legalDocumentsTookEffectOnTheFourteenthOfNovember2026() {
        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: LegalDocument.effective)
        #expect(day.year == 2026 && day.month == 11 && day.day == 14)
    }

    @Test func inlineMarkdownInTheDocumentsIsRendered() {
        let privacy = LegalDocument.document(.privacy)
        let rendered = privacy.sections.flatMap(\.blocks).flatMap { block -> [AttributedString] in
            switch block {
            case .paragraph(let text): [text]
            case .bullets(let items): items
            }
        }
        // Backticks become code spans, not literal characters.
        #expect(rendered.allSatisfy { !String($0.characters).contains("`") })
        #expect(rendered.contains { $0.runs.contains { $0.inlinePresentationIntent == .code } })
    }
}
