import MercuryAccounts
import MercuryUI
import SwiftUI

/// Follows a CLI sign-in: shows its output, offers the sign-in link (open, or copy to use in a private window) and,
/// for Claude, a field to paste the code shown after signing in on another device.
struct LoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingLogin

    @State private var lines: [String] = []
    @State private var link: URL?
    @State private var code = ""
    @State private var state: LoginState = .waiting

    enum LoginState: Equatable { case waiting, succeeded, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.m) {
            Text(pending.provider == .claude ? "Sign In to Claude" : "Sign In to Codex").font(.title3.bold())
            Text("Finish signing in in your browser. To use a different account than the one your browser is signed in to, copy the link and open it in a private window.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Link") { if let link { NSWorkspace.shared.open(link) } }
                    .disabled(link == nil)
                Button("Copy Link") {
                    guard let link else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
                .disabled(link == nil)
                if link == nil, state == .waiting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the sign-in link…").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(verbatim: lines.joined(separator: "\n"))
                    .font(MercuryFont.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MercurySpacing.s)
            }
            .frame(height: 140)
            .background(MercuryColor.codeBackground, in: RoundedRectangle(cornerRadius: MercuryRadius.control))
            if let interactive = pending.session as? any InteractiveLoginSession, state == .waiting {
                HStack {
                    SecureField("Paste code", text: $code)
                    Button("Send") {
                        interactive.send(code)
                        code = ""
                    }
                    .disabled(code.isEmpty)
                }
            }
            switch state {
            case .waiting: EmptyView()
            case .succeeded: Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(MercuryColor.okText)
            case .failed(let message): Label { Text(verbatim: message) } icon: { Image(systemName: "xmark.octagon.fill") }
                .foregroundStyle(MercuryColor.errorText)
            }
            HStack {
                Spacer()
                if state == .waiting {
                    Button("Cancel", role: .cancel) {
                        Task { await model.accountsController.abandon(pending); dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .glassProminentButtonStyle()
                }
            }
        }
        .padding(MercurySpacing.xl)
        .frame(width: 520)
        .interactiveDismissDisabled(state == .waiting)
        .task { await follow() }
    }

    private func follow() async {
        let output = Task { @MainActor in
            for await line in pending.session.output {
                lines.append(line)
                if lines.count > 200 { lines.removeFirst(lines.count - 200) }
                if link == nil { link = Self.firstLink(in: line) }
            }
        }
        do {
            try await pending.session.wait()
            await model.accountsController.finishLogin(pending)
            state = .succeeded
        } catch {
            state = .failed(error.localizedDescription)
            await model.accountsController.abandon(pending)
        }
        output.cancel()
    }

    static func firstLink(in line: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        return detector.firstMatch(in: line, range: range)?.url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
    }
}
