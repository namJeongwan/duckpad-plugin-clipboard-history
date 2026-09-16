import CryptoKit
import Foundation
import Darwin

// Signing reuses the persisted publisher key; it never generates or rotates it.
guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Usage: swift scripts/sign.swift PACKAGE [PRIVATE_KEY]") }
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("publisher.json"))) as! [String: String]
let package = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let defaultKey = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DuckpadDeveloper/Signing/com.duckpad/clipboard-release-1.private")
let keyURL = CommandLine.arguments.count == 3 ? URL(fileURLWithPath: CommandLine.arguments[2]) : defaultKey
var info = stat()
guard lstat(keyURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600 else { fatalError("Private key must be an owned regular mode-0600 file") }
guard !keyURL.resolvingSymlinksInPath().path.hasPrefix(repository.path + "/") else {
    fatalError("Keep the publisher key outside the worktree")
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
guard let publicText = metadata["publicKey"], let expected = Data(base64Encoded: publicText), key.publicKey.rawRepresentation == expected else {
    fatalError("Key does not match declared publisher identity")
}
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("plugin.json"))) as! [String: Any]
guard let publisher = manifest["publisher"] as? [String: String], publisher["id"] == metadata["id"], publisher["keyID"] == metadata["keyID"] else {
    fatalError("Package does not declare this publisher identity")
}
let inventory = try Data(contentsOf: package.appendingPathComponent("SHA256SUMS"))
var payload = Data("duckpad-extension-signature-v1\n".utf8); payload.append(inventory)
let signature = try key.signature(for: payload)
try (signature.base64EncodedString() + "\n").write(to: package.appendingPathComponent("SIGNATURE.ed25519"), atomically: true, encoding: .utf8)
print("Signed Clipboard History package")
