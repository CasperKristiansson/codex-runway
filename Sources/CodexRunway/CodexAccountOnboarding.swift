import Foundation

@MainActor
struct CodexAccountOnboarding {
    func add(configuration: CodexLoginConfiguration,
             signIn: @MainActor (URL, CodexLoginConfiguration) async throws -> Void = {
                 try await CodexAppServerClient().signIn(home: $0, configuration: $1)
             }) async throws -> Data {
        try configuration.validate()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runway-sign-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        // The child is stopped by signIn's defer before this private directory is removed.
        try await signIn(home, configuration)
        try Task.checkCancellation()
        guard let data = try CodexAuthFile(home: home).read() else { throw LoginSwitchError.signInFailed }
        return data
    }
}
