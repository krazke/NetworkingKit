import Foundation
import NetworkingCore

/// Auth server double with single-use refresh tokens: every successful refresh
/// invalidates the refresh token it consumed, like servers with refresh-token rotation.
/// Tokens are numbered: `access-N` / `refresh-N` are issued by the N-th refresh.
actor RotatingAuthServer {
    private(set) var refreshCount = 0
    private var validRefreshToken = "refresh-0"

    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        refreshCount += 1
        guard tokens.refreshToken == validRefreshToken else {
            throw URLError(.userAuthenticationRequired)
        }
        let generation = refreshCount
        validRefreshToken = "refresh-\(generation)"
        // Stay in flight long enough for concurrent 401s to overlap with this refresh.
        try await Task.sleep(for: .milliseconds(20))
        return AuthTokens(accessToken: "access-\(generation)", refreshToken: "refresh-\(generation)")
    }
}
