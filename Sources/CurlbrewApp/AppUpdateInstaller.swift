import AppKit
import CellarCore
import Foundation
import os

enum AppLocation {
    /// La copia que se puede reemplazar. Una app translocada es un temporal de cuarentena.
    static var bundle: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        guard Bundle.main.bundleIdentifier == AppUpdateFeed.bundleIdentifier else { return nil }
        if url.path.contains("/AppTranslocation/") { return nil }
        return url
    }
}

enum AppInstallError: LocalizedError {
    case download
    case redirect(String)
    case tooLarge
    case unpack(String)
    case bundle
    case replace(String)
    case relaunch(String)

    var errorDescription: String? {
        switch self {
        case .download:
            "No se pudo descargar la release"
        case .redirect(let host):
            "La descarga se desvió a \(host), que no es un servidor de releases de GitHub"
        case .tooLarge:
            "El archivo de la release es más grande de lo esperado"
        case .unpack(let message):
            "No se pudo abrir el zip: \(message)"
        case .bundle:
            "El zip no contiene Curlbrew.app con la versión y el identificador esperados"
        case .replace(let message):
            "No se pudo reemplazar la app: \(message)"
        case .relaunch(let message):
            "La app quedó actualizada, pero no se pudo volver a abrir: \(message)"
        }
    }
}

enum AppUpdateInstaller {
    static let maximumZipBytes: Int64 = 80 * 1024 * 1024
    static let maximumExpandedBytes: Int64 = 200 * 1024 * 1024
    static let allowedHosts: Set<String> = [
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    static func install(
        _ release: AppRelease,
        into bundle: URL,
        runner: any CommandRunning,
        log: @MainActor (String, Bool) -> Void
    ) async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("curlbrew-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent(release.assetName)
        await log("Descargando \(release.downloadURL.absoluteString)", false)
        try await download(release.downloadURL, to: zip)

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let extract = PlannedCommand(
            argv: ["/usr/bin/ditto", "-x", "-k", zip.path, unpacked.path],
            summary: "Abrir \(release.assetName)"
        )
        await log("$ \(extract.display)", false)
        let extracted = await runner.collect(extract)
        guard extracted.succeeded else {
            throw AppInstallError.unpack(failureText(extracted))
        }
        let expanded = try byteCount(unpacked)
        guard expanded > 0, expanded <= maximumExpandedBytes else { throw AppInstallError.tooLarge }

        let app = unpacked.appendingPathComponent("Curlbrew.app", isDirectory: true)
        let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard AppUpdateFeed.validateBundle(plist, version: release.version) else {
            throw AppInstallError.bundle
        }
        let binary = app.appendingPathComponent("Contents/MacOS/Curlbrew")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AppInstallError.bundle
        }
        let arch = PlannedCommand(
            argv: ["/usr/bin/lipo", "-archs", binary.path],
            summary: "Comprobar que el binario es arm64"
        )
        await log("$ \(arch.display)", false)
        let arches = await runner.collect(arch)
        guard arches.succeeded, arches.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else {
            throw AppInstallError.bundle
        }

        await log("Reemplazando \(bundle.path)", false)
        let copy = PlannedCommand(
            argv: ["/usr/bin/ditto", app.path, bundle.path],
            summary: "Instalar Curlbrew \(release.version)"
        )
        await log("$ \(copy.display)", false)
        let copied = await runner.collect(copy)
        guard copied.succeeded else { throw AppInstallError.replace(failureText(copied)) }

        let quarantine = PlannedCommand(
            argv: ["/usr/bin/xattr", "-cr", bundle.path],
            summary: "Quitar la cuarentena de la copia nueva"
        )
        await log("$ \(quarantine.display)", false)
        _ = await runner.collect(quarantine)
    }

    static func relaunch(_ bundle: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
                if let error {
                    continuation.resume(throwing: AppInstallError.relaunch(error.localizedDescription))
                } else {
                    continuation.resume()
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        let gate = ReleaseDownloader()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: gate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Curlbrew", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (temp, response) = try await session.download(for: request)
        if let host = gate.rejectedHost { throw AppInstallError.redirect(host) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppInstallError.download
        }
        guard let final = response.url, let host = final.host?.lowercased(), allowedHosts.contains(host) else {
            throw AppInstallError.redirect(response.url?.host ?? "desconocido")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        let bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0, bytes <= maximumZipBytes else { throw AppInstallError.tooLarge }
    }

    private static func byteCount(_ url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func failureText(_ result: CommandResult) -> String {
        if let failure = result.failure, !failure.isEmpty { return failure }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return detail }
        return "el comando terminó con código \(result.exitCode ?? -1)"
    }
}

private final class ReleaseDownloader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let rejected = OSAllocatedUnfairLock<String?>(initialState: nil)

    var rejectedHost: String? {
        rejected.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url,
              url.scheme == "https",
              let host = url.host?.lowercased(),
              AppUpdateInstaller.allowedHosts.contains(host) else {
            rejected.withLock { $0 = request.url?.host ?? "desconocido" }
            task.cancel()
            return nil
        }
        return request
    }
}
