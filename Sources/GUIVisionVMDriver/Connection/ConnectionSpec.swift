import Foundation

// MARK: - Spec Types

/// VNC connection parameters. Required for all connections.
public struct VNCSpec: Codable, Sendable {
    public let host: String
    public let port: Int
    public let password: String?

    public init(host: String, port: Int = 5900, password: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
    }
}

/// SSH connection parameters. Optional — enables shell access and file transfer.
public struct SSHSpec: Codable, Sendable {
    public let host: String
    public let port: Int
    public let user: String
    public let key: String?
    public let password: String?

    public init(host: String, port: Int = 22, user: String, key: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.key = key
        self.password = password
    }
}

/// Complete connection specification for a target machine.
/// Only `vnc` is required. SSH adds shell access and file transfer.
public struct ConnectionSpec: Codable, Sendable {
    public let vnc: VNCSpec
    public let ssh: SSHSpec?
    public let platform: Platform?

    public init(vnc: VNCSpec, ssh: SSHSpec? = nil, platform: Platform? = nil) {
        self.vnc = vnc
        self.ssh = ssh
        self.platform = platform
    }
}

// MARK: - Loading

extension ConnectionSpec {
    /// Load a connection spec from a JSON file.
    public static func load(from path: String) throws -> ConnectionSpec {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConnectionSpec.self, from: data)
    }

    /// Construct a connection spec from CLI flag values.
    public static func from(
        vnc: String,
        ssh: String? = nil,
        platform: String? = nil
    ) throws -> ConnectionSpec {
        let vncSpec = try parseVNCEndpoint(vnc)
        let sshSpec = try ssh.map { try parseSSHEndpoint($0) }
        let platformValue = try platform.map { try parsePlatform($0) }
        return ConnectionSpec(vnc: vncSpec, ssh: sshSpec, platform: platformValue)
    }
}

// MARK: - Endpoint Parsing

extension ConnectionSpec {
    static func parseVNCEndpoint(_ endpoint: String) throws -> VNCSpec {
        let (host, port) = try parseHostPort(endpoint, defaultPort: 5900)
        return VNCSpec(host: host, port: port)
    }

    static func parseSSHEndpoint(_ endpoint: String) throws -> SSHSpec {
        guard let atIndex = endpoint.firstIndex(of: "@") else {
            throw ConnectionSpecError.invalidSSHEndpoint(endpoint)
        }
        let user = String(endpoint[endpoint.startIndex..<atIndex])
        let hostPart = String(endpoint[endpoint.index(after: atIndex)...])
        let (host, port) = try parseHostPort(hostPart, defaultPort: 22)
        return SSHSpec(host: host, port: port, user: user)
    }

    static func parsePlatform(_ value: String) throws -> Platform {
        guard let platform = Platform(rawValue: value.lowercased()) else {
            throw ConnectionSpecError.invalidPlatform(value)
        }
        return platform
    }

    private static func parseHostPort(_ endpoint: String, defaultPort: Int) throws -> (String, Int) {
        let parts = endpoint.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        if host.isEmpty {
            throw ConnectionSpecError.emptyHost
        }
        if parts.count == 2 {
            guard let port = Int(parts[1]), port > 0, port <= 65535 else {
                throw ConnectionSpecError.invalidPort(String(parts[1]))
            }
            return (host, port)
        }
        return (host, defaultPort)
    }
}

// MARK: - Errors

public enum ConnectionSpecError: LocalizedError {
    case invalidSSHEndpoint(String)
    case invalidPlatform(String)
    case emptyHost
    case invalidPort(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSSHEndpoint(let endpoint):
            "Invalid SSH endpoint '\(endpoint)'. Expected format: user@host[:port]"
        case .invalidPlatform(let value):
            "Invalid platform '\(value)'. Expected: macos, windows, or linux"
        case .emptyHost:
            "Host cannot be empty"
        case .invalidPort(let port):
            "Invalid port '\(port)'. Expected a number between 1 and 65535"
        }
    }
}
