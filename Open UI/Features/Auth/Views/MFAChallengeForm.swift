import SwiftUI

/// Drives one MFA challenge to completion.
///
/// - `verify`: authenticator code, or a recovery code.
/// - `enroll` (also "replace authenticator"): QR / setup key, confirm a code, then
///   show the new recovery codes.
/// - `recover`: an operator reset token, which turns into a fresh enrollment.
struct MFAChallengeForm: View {
    let client: APIClient?
    let initialChallenge: MfaChallenge
    let accountLabel: String
    /// Called with the signed-in user (nil when replacing an authenticator).
    let onComplete: (User?) async -> Void
    var onChallengeChanged: (MfaChallenge) -> Void = { _ in }
    /// Called when the challenge can no longer be used and sign-in must restart.
    var onChallengeExpired: () -> Void = {}

    @Environment(\.theme) var theme
    @Environment(\.openURL) var openURL
    @State var challenge: MfaChallenge?
    @State var setup: MfaSetup?
    @State var code = ""
    @State var useRecovery = false
    @State var busy = false
    @State var error: String?
    @State var shake = 0
    @State var keyCopied = false
    @State var recoveryCodes: [String] = []
    @State var pendingUser: User?
    @State var finished = false

    var current: MfaChallenge { challenge ?? initialChallenge }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if !recoveryCodes.isEmpty {
                MFARecoveryCodesView(codes: recoveryCodes, continueTitle: String(localized: "Continue")) {
                    Task {
                        busy = true
                        await onComplete(pendingUser)
                        busy = false
                    }
                }
            } else {
                header
                if current.isEnroll { enrollSection }
                if !current.isEnroll || setup != nil { codeSection }
            }
        }
        .task(id: current.challengeToken) { await loadSetupIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text(subtitle)
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        if current.isEnroll { return String(localized: "Set up your authenticator") }
        if current.isRecover { return String(localized: "Recover your authenticator") }
        return String(localized: "Verify your sign-in")
    }

    private var subtitle: String {
        if current.isEnroll {
            return String(localized: "Scan the QR code, then enter the six-digit code from your authenticator app.")
        }
        if current.isRecover { return String(localized: "Enter the recovery token from your operator.") }
        return useRecovery
            ? String(localized: "Enter one of your saved recovery codes.")
            : String(localized: "Enter the six-digit code from your authenticator app.")
    }

    // MARK: Actions

    func loadSetupIfNeeded() async {
        guard current.isEnroll, setup == nil, let client else { return }
        busy = true
        error = nil
        do {
            setup = try await client.mfaEnrollStart(challengeToken: current.challengeToken)
        } catch {
            self.error = APIClient.mfaErrorMessage(error)
        }
        busy = false
    }

    func submit() async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty, !finished, let client else { return }
        busy = true
        error = nil
        do {
            if current.isRecover {
                let next = try await client.mfaRecover(challengeToken: current.challengeToken, resetToken: trimmed)
                code = ""
                setup = nil
                challenge = next
                onChallengeChanged(next)
            } else if current.isEnroll {
                let result = try await client.mfaEnrollConfirm(challengeToken: current.challengeToken, code: trimmed)
                code = ""
                finished = true
                Haptics.notify(.success)
                if result.codes.isEmpty {
                    await onComplete(result.user)
                } else {
                    pendingUser = result.user
                    recoveryCodes = result.codes
                }
            } else {
                let user = try await client.mfaVerify(
                    challengeToken: current.challengeToken,
                    code: trimmed,
                    recovery: useRecovery
                )
                code = ""
                finished = true
                Haptics.notify(.success)
                await onComplete(user)
            }
        } catch {
            self.error = APIClient.mfaErrorMessage(error)
            code = ""
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { shake += 1 }
            Haptics.notify(.error)
            if Self.isChallengeDead(error) { onChallengeExpired() }
        }
        busy = false
    }

    /// The challenge can't be retried (expired, too many codes, or MFA turned off).
    static func isChallengeDead(_ error: Error) -> Bool {
        guard case .httpError(let status, let message, _) = APIError.from(error) else { return false }
        let text = message?.lowercased() ?? ""
        return text.contains("expired") || text.contains("start again") || text.contains("sign in again")
            || (status == 403 && text.contains("mfa is disabled"))
    }
}
