import AppKit
import SuijinUI
import SwiftUI

/// Where people reach Tekmium Solutions about Suijin. Fill these in once the real addresses exist; each link stays
/// hidden while its value is nil, and the Contact section disappears while both are.
enum AboutLinks {
    /// The support mailbox, e.g. "support@example.com".
    static let supportEmail: String? = nil
    /// The public issue tracker or GitHub repository.
    static let issueTracker: URL? = nil

    /// A `mailto:` link for `email`; nil for anything that is not a plain address.
    static func mailURL(_ email: String?) -> URL? {
        guard let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty,
              email.wholeMatch(of: /[^@\s\/?#]+@[^@\s\/?#]+\.[^@\s\/?#]+/) != nil
        else { return nil }
        return URL(string: "mailto:\(email)")
    }
}

/// Name, version and copyright from the app bundle.
struct AppIdentity: Equatable {
    var name: String
    var version: String
    var build: String
    var copyright: String?

    init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        name = value("CFBundleDisplayName") ?? value("CFBundleName") ?? "Suijin"
        version = value("CFBundleShortVersionString") ?? "—"
        build = value("CFBundleVersion") ?? "—"
        copyright = value("NSHumanReadableCopyright")
    }

    static var current: AppIdentity { AppIdentity(info: Bundle.main.infoDictionary ?? [:]) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// An open-source project Suijin ships, with the license named in its checkout.
struct OpenSourceComponent: Identifiable {
    var name: String
    var license: String
    var id: String { name }

    /// Verified against each package's LICENSE/COPYING file; update together with `project.yml` and the packages.
    static var all: [OpenSourceComponent] {
        [
            OpenSourceComponent(name: "SwiftTerm", license: "MIT License"),
            OpenSourceComponent(name: "Sparkle", license: "MIT License"),
            OpenSourceComponent(name: "GRDB", license: "MIT License"),
            OpenSourceComponent(name: "MarkdownUI", license: "MIT License"),
            OpenSourceComponent(name: "NetworkImage", license: "MIT License"),
            OpenSourceComponent(name: "swift-cmark", license: "BSD 2-Clause License"),
            OpenSourceComponent(name: "SwiftTreeSitter", license: "BSD 3-Clause License"),
            OpenSourceComponent(name: "Tree-sitter", license: "MIT License"),
            OpenSourceComponent(
                name: String(localized: "Tree-sitter grammars for Swift, JavaScript, TypeScript, Python, JSON, Go, Rust and Markdown"),
                license: "MIT License"),
        ]
    }
}

/// Settings → About: what Suijin is, its version, who made it, contact links, the legal documents and the
/// open-source components it uses.
struct AboutSettings: View {
    /// `-SuijinAboutDocument terms|privacy` opens that document at launch, for screenshots.
    @State private var openDocument = UserDefaults.standard.string(forKey: "SuijinAboutDocument")
        .flatMap(LegalDocument.Kind.init(rawValue:))
    private let identity = AppIdentity.current

    var body: some View {
        Form {
            Section {
                AboutHeader(identity: identity)
            }
            Section {
                LabeledContent("Created by") { Text(verbatim: "Vo Van Vu") }
                LabeledContent("Developed by") { Text(verbatim: "Tekmium Solutions") }
            } header: {
                Text("Credits")
            } footer: {
                if let copyright = identity.copyright {
                    Text(verbatim: copyright).font(.caption).foregroundStyle(.secondary)
                }
            }
            contactSection
            Section {
                ForEach(LegalDocument.Kind.allCases) { kind in
                    LegalDocumentRow(kind: kind) { openDocument = kind }
                }
            } header: {
                Text("Legal")
            }
            Section {
                ForEach(OpenSourceComponent.all) { component in
                    LabeledContent {
                        Text(verbatim: component.license)
                    } label: {
                        Text(verbatim: component.name).lineLimit(2)
                    }
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("Suijin is built with these open-source projects, each used under its own license.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $openDocument) { kind in
            LegalDocumentSheet(document: LegalDocument.document(kind))
        }
    }

    @ViewBuilder private var contactSection: some View {
        let mail = AboutLinks.mailURL(AboutLinks.supportEmail)
        if mail != nil || AboutLinks.issueTracker != nil {
            Section {
                if let mail, let email = AboutLinks.supportEmail {
                    LabeledContent("Support") {
                        Link(destination: mail) { Text(verbatim: email).lineLimit(1).truncationMode(.middle) }
                            .accessibilityLabel(Text("Email support"))
                    }
                }
                if let tracker = AboutLinks.issueTracker {
                    LabeledContent("Issues") {
                        Link(destination: tracker) {
                            Text(verbatim: tracker.host() ?? tracker.absoluteString).lineLimit(1).truncationMode(.middle)
                        }
                        .help(Text(verbatim: tracker.absoluteString))
                        .accessibilityLabel(Text("Open the issue tracker"))
                    }
                }
            } header: {
                Text("Contact")
            }
        }
    }
}

/// The app icon beside the name, version and a one-line description.
private struct AboutHeader: View {
    let identity: AppIdentity

    var body: some View {
        HStack(alignment: .center, spacing: SuijinSpacing.l) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SuijinSpacing.xs) {
                Text(verbatim: identity.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Version \(identity.version) (\(identity.build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Run Claude Code and Codex agents side by side on your Mac, each in its own git worktree, with several accounts and a native diff viewer.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SuijinSpacing.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SuijinSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// A legal document's title and effective date, with a button that opens it.
private struct LegalDocumentRow: View {
    let kind: LegalDocument.Kind
    let open: () -> Void

    var body: some View {
        LabeledContent {
            Button("View", action: open)
                .accessibilityLabel(Text("View \(title)"))
        } label: {
            Text(verbatim: title)
            Text("Effective \(LegalDocument.effective, format: .dateTime.year().month(.wide).day())")
        }
    }

    private var title: String { kind == .terms ? String(localized: "Terms of Service") : String(localized: "Privacy & Security") }
}

/// A legal document in a sheet: title, effective date, then its headed sections in a scroll view.
struct LegalDocumentSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SuijinSpacing.l) {
                    VStack(alignment: .leading, spacing: SuijinSpacing.xs) {
                        Text(verbatim: document.title)
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Effective \(LegalDocument.effective, format: .dateTime.year().month(.wide).day())")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        LegalSectionView(section: section)
                    }
                }
                .padding(SuijinSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SuijinSpacing.l)
        }
        .frame(minWidth: 460, idealWidth: 600, maxWidth: 760, minHeight: 360, idealHeight: 540)
        .accessibilityIdentifier("legalDocument.\(document.kind.rawValue)")
    }
}

private struct LegalSectionView: View {
    let section: LegalDocument.Section

    var body: some View {
        VStack(alignment: .leading, spacing: SuijinSpacing.s) {
            if let heading = section.heading {
                Text(verbatim: heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(text).fixedSize(horizontal: false, vertical: true)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: SuijinSpacing.xs) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: SuijinSpacing.s) {
                                Text(verbatim: "•").foregroundStyle(.secondary).accessibilityHidden(true)
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}
