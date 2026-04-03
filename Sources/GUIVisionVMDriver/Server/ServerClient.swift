import CryptoKit
import Foundation

/// Client-side handle for a per-`ConnectionSpec` server instance.
///
/// This type will be expanded in later tasks (Tasks 6 and 7) with HTTP
/// transport and auto-start logic. For now it only exposes the static
/// socket/PID path computation helpers.
public enum ServerClient {

    // MARK: - Path computation

    /// Returns the Unix domain socket path for the server that handles `spec`.
    ///
    /// The path is deterministic: given the same `ConnectionSpec` value, every
    /// independent CLI invocation will compute the same path and therefore find
    /// the same server process.
    ///
    /// Algorithm:
    /// 1. JSON-encode `spec` with `.sortedKeys` so key order is canonical.
    /// 2. SHA-256 hash the UTF-8 bytes.
    /// 3. Hex-encode the digest and take the first 16 characters.
    /// 4. Return `/tmp/guivision-{hex}.sock`.
    public static func socketPath(for spec: ConnectionSpec) -> String {
        "/tmp/guivision-\(hexPrefix(for: spec)).sock"
    }

    /// Returns the PID-file path that accompanies the socket for `spec`.
    ///
    /// Follows the same naming convention as `socketPath(for:)`, replacing
    /// the `.sock` extension with `.pid`.
    public static func pidPath(for spec: ConnectionSpec) -> String {
        "/tmp/guivision-\(hexPrefix(for: spec)).pid"
    }

    // MARK: - Private helpers

    /// Computes the 16-character lowercase hex prefix used in both path kinds.
    private static func hexPrefix(for spec: ConnectionSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // JSONEncoder.encode(_:) only throws for types that implement custom
        // encoding with errors; ConnectionSpec is a plain Codable struct and
        // will never throw in practice.
        let data = (try? encoder.encode(spec)) ?? Data()
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
