import Foundation

public protocol Locating: Sendable {
    func locate(_ name: String) -> String?
}

public struct BinaryLocator: Locating, Sendable, Equatable {
    public var searchPaths: [String]

    public init(searchPaths: [String]) {
        self.searchPaths = searchPaths
    }

    public static func extraPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "\(home)/Library/pnpm/bin",
            "\(home)/.cargo/bin",
            "\(home)/.deno/bin",
            "\(home)/.volta/bin",
            "\(home)/.nix-profile/bin",
        ]
    }

    public static func mergedSearchPaths(path: String, home: String = NSHomeDirectory()) -> [String] {
        var parts = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in extraPaths(home: home) where !parts.contains(extra) {
            parts.append(extra)
        }
        return parts
    }

    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> BinaryLocator {
        BinaryLocator(searchPaths: mergedSearchPaths(path: env["PATH"] ?? "", home: home))
    }

    public func locate(_ name: String) -> String? {
        let fileManager = FileManager.default
        if name.contains("/") {
            return fileManager.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public struct StaticLocator: Locating {
    public var paths: [String: String]

    public init(paths: [String: String]) {
        self.paths = paths
    }

    public func locate(_ name: String) -> String? {
        if let path = paths[name] { return path }
        return paths[(name as NSString).lastPathComponent]
    }
}
