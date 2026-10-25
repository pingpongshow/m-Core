import Foundation
import MeshCoreKit

// MARK: Rooms and repeaters

extension MessagingService {
    /// Logs in to a room server or repeater; waits for the radio's login push.
    public func login(to keyHex: String, password: String, timeout: Duration = .seconds(30)) async throws -> LoginResult {
        guard let session, let key = PublicKey(hex: keyHex) else { throw MessagingError.notConnected }
        _ = try await session.request(.sendLogin(to: key, password: password)) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        do {
            return try await loginWaiter.wait(for: key.prefix.hex, timeout: timeout)
        } catch RemoteRequestError.timedOut {
            throw MessagingError.loginTimedOut
        } catch RemoteRequestError.notConnected {
            throw MessagingError.notConnected
        }
    }

    func resolveLogin(prefix: KeyPrefix, with result: Result<LoginResult, Error>) {
        loginWaiter.resolve(prefix.hex, with: result)
    }
}
