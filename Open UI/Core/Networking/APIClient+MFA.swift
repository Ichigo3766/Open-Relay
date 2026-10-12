import Foundation

/// Two-factor sign-in endpoints (`/api/v1/auths/mfa/*`).
///
/// The challenge token returned by sign-in is the only credential for the
/// enroll / verify / recover steps — those requests are sent unauthenticated.
/// The management calls (status, replace, recovery codes) need a real session.
extension APIClient {

    /// Sends an MFA request straight on the server session (custom headers,
    /// cookies and trust still apply). It deliberately skips the shared
    /// validation: MFA answers a wrong code with 401, which must never be
    /// treated as an expired session (auto sign-out / native SSO renewal).
    private func mfaSend(_ path: String, method: HTTPMethod, body: [String: Any]?, authenticated: Bool) async throws -> Data {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let request = try network.buildRequest(
            path: "/api/v1/auths/mfa/\(path)",
            method: method,
            body: bodyData,
            authenticated: authenticated,
            timeout: 30
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.session.data(for: request)
        } catch {
            throw APIError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = json?["detail"] as? String
            throw APIError.httpError(statusCode: status, message: detail, data: data)
        }
        return data
    }

    private func mfaPost(_ path: String, body: [String: Any], authenticated: Bool) async throws -> Data {
        try await mfaSend(path, method: .post, body: body, authenticated: authenticated)
    }

    /// Stores a session from an MFA response and loads the full user.
    private func installMFASession(_ data: Data) async throws -> User {
        let response: AuthResponse
        do {
            response = try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            throw APIError.responseDecoding(underlying: error, data: data)
        }
        network.saveAuthToken(response.token)
        if let fullUser = try? await getCurrentUser() { return fullUser }
        return User(
            id: response.id ?? "",
            username: response.name ?? response.email ?? "",
            email: response.email ?? "",
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    /// POST `/auths/mfa/enroll/start` — creates (or reuses) the pending secret.
    func mfaEnrollStart(challengeToken: String) async throws -> MfaSetup {
        let data = try await mfaPost("enroll/start", body: ["challenge_token": challengeToken], authenticated: false)
        do {
            return try JSONDecoder().decode(MfaSetup.self, from: data)
        } catch {
            throw APIError.responseDecoding(underlying: error, data: data)
        }
    }

    /// POST `/auths/mfa/enroll/confirm`. Returns the new recovery codes and, for a
    /// sign-in enrollment, the signed-in user (`nil` when replacing an authenticator).
    func mfaEnrollConfirm(challengeToken: String, code: String) async throws -> (codes: [String], user: User?) {
        let data = try await mfaPost(
            "enroll/confirm",
            body: ["challenge_token": challengeToken, "code": code, "recovery": false],
            authenticated: false
        )
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let codes = json["recovery_codes"] as? [String] ?? []
        guard json["token"] is String else { return (codes, nil) }
        return (codes, try await installMFASession(data))
    }

    /// POST `/auths/mfa/verify` — authenticator or recovery code. Installs the session.
    func mfaVerify(challengeToken: String, code: String, recovery: Bool) async throws -> User {
        let data = try await mfaPost(
            "verify",
            body: ["challenge_token": challengeToken, "code": code, "recovery": recovery],
            authenticated: false
        )
        return try await installMFASession(data)
    }

    /// POST `/auths/mfa/recover` — redeems an operator reset token for a new enrollment.
    func mfaRecover(challengeToken: String, resetToken: String) async throws -> MfaChallenge {
        let data = try await mfaPost(
            "recover",
            body: ["challenge_token": challengeToken, "reset_token": resetToken],
            authenticated: false
        )
        return try JSONDecoder().decode(MfaChallenge.self, from: data)
    }

    /// GET `/auths/mfa/status` — the current user's authenticator state.
    /// Throws a 404 when the server has no two-factor support.
    func mfaStatus() async throws -> MfaStatus {
        let data = try await mfaSend("status", method: .get, body: nil, authenticated: true)
        return try JSONDecoder().decode(MfaStatus.self, from: data)
    }

    /// POST `/auths/mfa/replace` — verifies a current code, then starts a replacement enrollment.
    func mfaReplace(code: String, recovery: Bool) async throws -> MfaChallenge {
        let data = try await mfaPost("replace", body: ["code": code, "recovery": recovery], authenticated: true)
        return try JSONDecoder().decode(MfaChallenge.self, from: data)
    }

    /// POST `/auths/mfa/recovery/codes` — issues new recovery codes. Signs out every device.
    func mfaRegenerateRecoveryCodes(code: String, recovery: Bool) async throws -> [String] {
        let data = try await mfaPost("recovery/codes", body: ["code": code, "recovery": recovery], authenticated: true)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return json["recovery_codes"] as? [String] ?? []
    }

    /// Readable message for MFA endpoint failures (the server's `detail` text).
    static func mfaErrorMessage(_ error: Error) -> String {
        let apiError = APIError.from(error)
        if case .httpError(let status, let message, _) = apiError {
            if message == "reauthentication_required" {
                return String(localized: "Sign in again before changing your authenticator settings.")
            }
            if let message, !message.isEmpty { return message }
            if status == 401 { return String(localized: "Invalid or already used code.") }
        }
        return apiError.errorDescription ?? String(localized: "Authentication failed. Please try again.")
    }
}
