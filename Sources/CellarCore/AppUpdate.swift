import Foundation

public struct AppRelease: Equatable, Sendable {
    public var version: String
    public var tag: String
    public var assetName: String
    public var downloadURL: URL
    public var notesURL: URL

    public init(version: String, tag: String, assetName: String, downloadURL: URL, notesURL: URL) {
        self.version = version
        self.tag = tag
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.notesURL = notesURL
    }
}

public enum AppUpdateFailure: Error, Equatable, LocalizedError {
    case unreadable
    case noZip(String)
    case rejectedURL

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "La respuesta de GitHub no es una release válida"
        case .noZip(let version):
            "La release \(version) no incluye Curlbrew-\(version).zip"
        case .rejectedURL:
            "La descarga no apunta a la release de Izzy2024/curl-brew"
        }
    }
}

/// La release pública sale de GitHub. Un push a `main` no es una actualización:
/// solo cuenta `releases/latest` con un zip cuyo nombre y URL coinciden con el tag.
public enum AppUpdateFeed {
    public static let repository = "Izzy2024/curl-brew"
    public static let bundleIdentifier = "app.curlbrew.macos"
    public static let feedURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// `nil` cuando no hay una versión estable más nueva.
    /// Lanza si la release más nueva no trae el zip esperado o la URL no es de este repo.
    public static func release(from data: Data, newerThan current: String) throws -> AppRelease? {
        guard data.count <= 1_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppUpdateFailure.unreadable
        }
        if root["draft"] as? Bool == true { return nil }
        if root["prerelease"] as? Bool == true { return nil }
        guard let tag = root["tag_name"] as? String, tag.hasPrefix("v") else {
            throw AppUpdateFailure.unreadable
        }
        let version = String(tag.dropFirst())
        guard isStableVersion(version) else { throw AppUpdateFailure.unreadable }
        guard VersionText.compare(current, version) == .orderedAscending else { return nil }
        guard let assets = root["assets"] as? [[String: Any]] else {
            throw AppUpdateFailure.noZip(version)
        }
        let name = "Curlbrew-\(version).zip"
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              let text = asset["browser_download_url"] as? String,
              let url = downloadURL(text, version: version, name: name) else {
            throw AppUpdateFailure.noZip(version)
        }
        let notes = URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
        return AppRelease(version: version, tag: tag, assetName: name, downloadURL: url, notesURL: notes)
    }

    public static func validateBundle(_ data: Data, version: String) -> Bool {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return object["CFBundleIdentifier"] as? String == bundleIdentifier
            && object["CFBundleShortVersionString"] as? String == version
            && object["CFBundleExecutable"] as? String == "Curlbrew"
    }

    static func isStableVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Solo el zip de este repositorio, en https, sin usuario ni query.
    static func downloadURL(_ text: String, version: String, name: String) -> URL? {
        guard let url = URL(string: text),
              url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/\(repository)/releases/download/v\(version)/\(name)" else {
            return nil
        }
        return url
    }
}
