import SwiftUI

/// Risk level of an operation (SPEC §7.2, `Xác nhận theo rủi ro` / risk-based confirmation).
public enum RiskLevel: String, Sendable, CaseIterable, Codable {
    /// Runs immediately, no prompt.
    case safe
    /// Asks again and shows the real command.
    case confirm
    /// Red button, the user must retype the name (host/app/volume), optional Touch ID.
    case danger

    public var label: Text {
        switch self {
        case .safe: Text("Safe", bundle: .module)
        case .confirm: Text("Needs confirmation", bundle: .module)
        case .danger: Text("Dangerous", bundle: .module)
        }
    }

    public var tone: StatusTone {
        switch self {
        case .safe: .ok
        case .confirm: .warning
        case .danger: .error
        }
    }
}

/// A confirmation request before running an operation.
public struct RiskConfirmationRequest: Identifiable, Sendable {
    public let id = UUID()
    public var level: RiskLevel
    public var title: String
    public var message: String
    /// The real command that will run, shown verbatim.
    public var command: String?
    /// The string the user must retype when `level == .danger` (usually the host name).
    public var typeToConfirm: String?
    public var confirmTitle: String
    public var requiresBiometrics: Bool

    public init(
        level: RiskLevel,
        title: String,
        message: String = "",
        command: String? = nil,
        typeToConfirm: String? = nil,
        confirmTitle: String? = nil,
        requiresBiometrics: Bool = false
    ) {
        self.level = level
        self.title = title
        self.message = message
        self.command = command
        self.typeToConfirm = typeToConfirm
        self.confirmTitle = confirmTitle ?? String(localized: "Continue", bundle: .module)
        self.requiresBiometrics = requiresBiometrics
    }

    /// Safe operations need no prompt.
    public var needsPrompt: Bool { level != .safe }

    /// The confirm button is enabled only when the user types the required string exactly (case-sensitive,
    /// leading/trailing whitespace trimmed). Always enabled when no typing is required.
    public func canConfirm(typed: String) -> Bool {
        guard level == .danger, let expected = typeToConfirm, !expected.isEmpty else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }
}

/// Risk-based confirmation dialog. The caller decides on Touch ID via `authenticate`. A sheet rather than
/// `.alert`/`.confirmationDialog`: the dialog must show the real command with a copy button and, for dangerous
/// operations, a field where the user retypes the host name, which system alerts cannot lay out.
public struct RiskConfirmationView: View {
    let request: RiskConfirmationRequest
    let authenticate: @MainActor () async -> Bool
    let onFinish: @MainActor (Bool) -> Void
    @State private var typed = ""
    @State private var authFailed = false
    @FocusState private var fieldFocused: Bool

    public init(
        request: RiskConfirmationRequest,
        authenticate: @escaping @MainActor () async -> Bool = { true },
        onFinish: @escaping @MainActor (Bool) -> Void
    ) {
        self.request = request
        self.authenticate = authenticate
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: SuijinSpacing.m) {
            Image(systemName: request.level == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(request.level.tone.color)
            Text(request.title).font(.headline).multilineTextAlignment(.center)
            if !request.message.isEmpty {
                Text(request.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let command = request.command {
                CommandEquivalentView(command)
            }
            if request.level == .danger, let expected = request.typeToConfirm {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type \(Text(expected).font(SuijinFont.monoSmall).bold()) to confirm:", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(SuijinFont.mono)
                        .focused($fieldFocused)
                        .accessibilityIdentifier("risk.typeToConfirm")
                        .accessibilityLabel(Text("Type again to confirm", bundle: .module))
                }
            }
            if authFailed {
                Text("Authentication failed.", bundle: .module).font(.caption).foregroundStyle(SuijinColor.errorText)
            }
            VStack(spacing: 6) {
                Button(role: request.level == .danger ? .destructive : nil) {
                    Task { await confirm() }
                } label: {
                    Text(request.confirmTitle).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(request.level == .danger ? nil : .defaultAction)
                .tint(request.level == .danger ? SuijinColor.error : nil)
                .glassProminentButtonStyle()
                .disabled(!request.canConfirm(typed: typed))
                .accessibilityIdentifier("risk.confirm")

                Button { onFinish(false) } label: { Text("Cancel", bundle: .module).frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("risk.cancel")
            }
            .controlSize(.large)
        }
        .padding(SuijinSpacing.xl)
        .frame(width: 400)
        .onAppear { fieldFocused = request.typeToConfirm != nil }
    }

    private func confirm() async {
        guard request.canConfirm(typed: typed) else { return }
        if request.requiresBiometrics {
            guard await authenticate() else { authFailed = true; return }
        }
        onFinish(true)
    }
}
