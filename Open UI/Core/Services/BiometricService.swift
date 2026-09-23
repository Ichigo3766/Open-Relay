import Foundation
import LocalAuthentication
import os.log

// MARK: - Biometric Error

/// Typed errors from biometric authentication, with user-friendly messages.
enum BiometricError: LocalizedError {
    case notAvailable
    case notEnrolled
    case lockout
    case userCancelled
    case userFallback
    case systemCancel
    case passcodeNotSet
    case credentialsNotFound
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Biometric authentication is not available on this device."
        case .notEnrolled:
            return "No biometrics are enrolled. Please set up Face ID or Touch ID in Settings."
        case .lockout:
            return "Biometric authentication is locked out due to too many failed attempts. Please use your passcode."
        case .userCancelled:
            return nil // Intentional cancel — no error shown to user
        case .userFallback:
            return nil // User chose fallback — handled by caller
        case .systemCancel:
            return nil // System interrupted — no error shown
        case .passcodeNotSet:
            return "No passcode is set. Please enable a passcode in Settings to use Face ID."
        case .credentialsNotFound:
            return "No saved credentials found. Please sign in manually first."
        case .unknown(let error):
            return error.localizedDescription
        }
    }

    /// Whether this error should be silently ignored (user intentionally cancelled).
    var isSilent: Bool {
        switch self {
        case .userCancelled, .systemCancel, .userFallback:
            return true
        default:
            return false
        }
    }
}

// MARK: - Biometric Type

nonisolated enum BiometricType {
    case faceID
    case touchID
    case opticID
    case none

    nonisolated var displayName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Biometrics"
        }
    }

    nonisolated var systemImageName: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "faceid"
        }
    }
}

// MARK: - BiometricService

/// Clean async wrapper around `LAContext` for biometric authentication.
///
/// Use this service for all biometric operations. Each authentication attempt
/// creates a fresh `LAContext` (contexts are single-use by design).
///
/// Usage:
/// ```swift
/// let result = await BiometricService.shared.authenticate(reason: "Sign in")
/// switch result {
/// case .success: // proceed
/// case .failure(let error) where !error.isSilent: // show error
/// case .failure: break // silent cancel
/// }
/// ```
@MainActor
final class BiometricService: Sendable {

    static let shared = BiometricService()

    private let logger = Logger(subsystem: "com.openui", category: "Biometrics")

    private init() {}

    // MARK: - Capability Check

    /// Whether biometric authentication (Face ID / Touch ID) is available and enrolled.
    nonisolated var canUseBiometrics: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Whether device authentication (biometrics OR passcode) is available.
    nonisolated var canUseDeviceAuthentication: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// The biometric type available on this device.
    nonisolated var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    /// Human-readable name for the biometric type ("Face ID", "Touch ID", etc.).
    nonisolated var biometricTypeName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return BiometricType.none.displayName
        }
        switch context.biometryType {
        case .faceID: return BiometricType.faceID.displayName
        case .touchID: return BiometricType.touchID.displayName
        case .opticID: return BiometricType.opticID.displayName
        default: return BiometricType.none.displayName
        }
    }

    /// SF Symbol name for the biometric type icon.
    nonisolated var biometricIconName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return BiometricType.none.systemImageName
        }
        switch context.biometryType {
        case .faceID: return BiometricType.faceID.systemImageName
        case .touchID: return BiometricType.touchID.systemImageName
        case .opticID: return BiometricType.opticID.systemImageName
        default: return BiometricType.none.systemImageName
        }
    }

    // MARK: - Authentication

    /// Authenticates using biometrics only (Face ID / Touch ID — no passcode fallback).
    ///
    /// - Parameter reason: The localized string shown in the system biometric dialog.
    /// - Returns: `.success(LAContext)` with the evaluated context on success (reuse it for
    ///   Keychain reads to avoid a second Face ID prompt), or `.failure(BiometricError)`.
    func authenticate(reason: String) async -> Result<LAContext, BiometricError> {
        guard canUseBiometrics else {
            logger.warning("Biometrics not available or not enrolled")
            let context = LAContext()
            var error: NSError?
            context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            return .failure(mapLAError(error))
        }

        // Always create a fresh context — LAContext is single-use
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if success {
                logger.info("Biometric authentication succeeded")
                // Return the evaluated context so callers can reuse it for Keychain
                // operations — this prevents a second Face ID prompt when reading
                // credentials protected by .userPresence access control.
                return .success(context)
            } else {
                logger.warning("Biometric authentication returned false without error")
                return .failure(.unknown(NSError(domain: LAErrorDomain, code: LAError.authenticationFailed.rawValue)))
            }
        } catch let laError as LAError {
            let mapped = mapLAError(laError)
            if !mapped.isSilent {
                logger.warning("Biometric auth failed: \(laError.localizedDescription)")
            }
            return .failure(mapped)
        } catch {
            logger.error("Biometric auth unexpected error: \(error.localizedDescription)")
            return .failure(.unknown(error))
        }
    }

    // MARK: - Private Helpers

    /// Maps an `LAError` to a typed `BiometricError`.
    private func mapLAError(_ error: LAError) -> BiometricError {
        switch error.code {
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryLockout:
            return .lockout
        case .userCancel, .appCancel:
            return .userCancelled
        case .userFallback:
            return .userFallback
        case .systemCancel:
            return .systemCancel
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return .unknown(error)
        }
    }

    /// Maps an optional `NSError` (from `canEvaluatePolicy`) to a `BiometricError`.
    private func mapLAError(_ nsError: NSError?) -> BiometricError {
        guard let nsError else { return .notAvailable }
        if let laError = nsError as? LAError {
            return mapLAError(laError)
        }
        let code = LAError.Code(rawValue: nsError.code)
        switch code {
        case .biometryNotAvailable: return .notAvailable
        case .biometryNotEnrolled: return .notEnrolled
        case .biometryLockout: return .lockout
        case .passcodeNotSet: return .passcodeNotSet
        default: return .notAvailable
        }
    }
}
