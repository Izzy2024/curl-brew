import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var label: String
    public var fraction: Double?
    public var transferredText: String?
    public var remainingText: String?
    public var percentText: String?
    public var cliBarLine: String
    public var isFinished: Bool

    public init(
        label: String,
        fraction: Double? = nil,
        transferredText: String? = nil,
        remainingText: String? = nil,
        percentText: String? = nil,
        cliBarLine: String = "",
        isFinished: Bool = false
    ) {
        self.label = label
        self.fraction = fraction
        self.transferredText = transferredText
        self.remainingText = remainingText
        self.percentText = percentText
        self.cliBarLine = cliBarLine
        self.isFinished = isFinished
    }
}

public enum ProgressParser {
    private static let spinnerScalars: Set<UnicodeScalar> = Set(
        "⠋⠙⠚⠞⠖⠦⠴⠲⠳⠓⠹⠸⠼⠧⠇⠏✔✘|/-\\".unicodeScalars
    )

    private static let homebrewPhasePrefixes = [
        "Downloading",
        "Fetching",
        "Pouring",
        "Installing",
        "Moving",
        "Backing",
        "Linking",
        "Upgrading",
    ]

    public static func stripTerminalSequences(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == "\u{001B}" {
                guard index + 1 < scalars.count else {
                    index += 1
                    continue
                }
                let next = scalars[index + 1]
                if next == "[" {
                    // CSI: ESC [ ... final byte 0x40...0x7E
                    var end = index + 2
                    while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) {
                        end += 1
                    }
                    index = end < scalars.count ? end + 1 : scalars.count
                    continue
                }
                if next == "]" || next == "P" || next == "^" || next == "_" || next == "X" {
                    // OSC / DCS / PM / APC / SOS terminated by BEL (0x07), ST (ESC \), or 0x9C
                    var end = index + 2
                    while end < scalars.count {
                        if scalars[end] == "\u{0007}" || scalars[end] == "\u{009C}" {
                            end += 1
                            break
                        }
                        if scalars[end] == "\u{001B}", end + 1 < scalars.count, scalars[end + 1] == "\\" {
                            end += 2
                            break
                        }
                        end += 1
                    }
                    index = end
                    continue
                }
                // Other escape sequence: ESC [intermediate 0x20..0x2F]* [final 0x30..0x7E]
                var end = index + 1
                while end < scalars.count, (0x20...0x2F).contains(scalars[end].value) {
                    end += 1
                }
                if end < scalars.count, (0x30...0x7E).contains(scalars[end].value) {
                    index = end + 1
                } else {
                    index += 1
                }
                continue
            }

            // C1 CSI (0x9B)
            if scalar == "\u{009B}" {
                var end = index + 1
                while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) {
                    end += 1
                }
                index = end < scalars.count ? end + 1 : scalars.count
                continue
            }

            // Keep \n, \r, \t; drop other ASCII and C1 control scalars
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                output.append(scalar)
            } else if scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value) {
                output.append(scalar)
            }
            index += 1
        }

        return String(output)
    }

    public static func splitSegments(_ raw: String) -> [String] {
        let stripped = stripTerminalSequences(raw)
        return stripped
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { segment in
                guard !segment.isEmpty else { return false }
                return !isSpinnerOnly(segment)
            }
    }

    public static func parse(_ rawLine: String) -> DownloadProgress? {
        let segments = splitSegments(rawLine)
        guard let line = segments.last else { return nil }

        if let brew = parseHomebrewQueue(line) { return brew }
        if let curlBar = parseCurlProgressBar(line) { return curlBar }
        if let curlTable = parseCurlMeter(line) { return curlTable }
        if let pnpmDownload = parsePnpmDownload(line) { return pnpmDownload }
        if let pnpmProgress = parsePnpmProgress(line) { return pnpmProgress }
        if let npmFetch = parseNpmHttpFetch(line) { return npmFetch }
        if let brewHeading = parseHomebrewHeading(line) { return brewHeading }
        return nil
    }

    public static func isNonErrorStderr(_ rawLine: String) -> Bool {
        guard let line = splitSegments(rawLine).last else { return true }
        if parse(line) != nil { return true }

        // Standard curl progress table header
        if (line.contains("% Total") && line.contains("% Received"))
            || (line.contains("Dload") && line.contains("Upload") && line.contains("Spent"))
        {
            return true
        }

        // curl --progress-bar warmup lines like "#=#=#" or "##O#-#"
        if isCurlWarmupBar(line) {
            return true
        }

        let lower = line.lowercased()
        if lower.hasPrefix("npm http ")
            || lower.hasPrefix("npm info ")
            || lower.hasPrefix("npm notice ")
            || lower.hasPrefix("npm timing ")
        {
            return true
        }

        if line.hasPrefix("==> ") || line.hasPrefix("✔") {
            return true
        }

        return false
    }

    public static func asciiBar(fraction: Double?, width: Int = 20) -> String {
        guard let fraction else {
            return "[\(String(repeating: "·", count: width))]"
        }
        let clamped = min(max(fraction, 0), 1)
        let filled = Int((clamped * Double(width)).rounded())
        return "[\(String(repeating: "#", count: filled))\(String(repeating: "·", count: width - filled))]"
    }

    // MARK: - Private Parsers

    private static func isSpinnerOnly(_ text: String) -> Bool {
        var sawSpinner = false
        for scalar in text.unicodeScalars {
            if scalar == "\u{FE0E}" || scalar == "\u{FE0F}" || scalar == " " {
                continue
            }
            if spinnerScalars.contains(scalar) || (0x2800...0x28FF).contains(scalar.value) {
                sawSpinner = true
            } else {
                return false
            }
        }
        return sawSpinner
    }

    private static func isCurlWarmupBar(_ text: String) -> Bool {
        var sawGlyph = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "#", "=", "O", "-":
                sawGlyph = true
            case " ":
                continue
            default:
                return false
            }
        }
        return sawGlyph
    }

    private static func parseHomebrewQueue(_ line: String) -> DownloadProgress? {
        let pattern = #"^(?:[⠋⠙⠚⠞⠖⠦⠴⠲⠳⠓✔✘]\x{FE0E}?\s*)?(.+?)\s+(?:#+\s+)?(Preparing|Downloading|Downloaded|Verifying|Verified|Extracting)\s+([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|B))\s*/\s*([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|B)|-+)$"#
        guard let match = firstMatch(pattern, in: line), match.count == 5 else {
            return nil
        }

        let rawLabel = match[1]
            .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let label = rawLabel.isEmpty ? "Descargando" : rawLabel
        let phase = match[2]
        let fetchedRaw = match[3]
        let totalRaw = match[4]

        guard let fetchedBytes = ByteSize.parse(fetchedRaw) else { return nil }
        let fetchedFormatted = ByteSize.format(fetchedBytes)
        let phaseFinished = phase == "Downloaded" || phase == "Verified"

        if totalRaw.allSatisfy({ $0 == "-" }) {
            let cliBar = "\(asciiBar(fraction: nil)) \(label) · \(fetchedFormatted)"
            return DownloadProgress(
                label: label,
                fraction: nil,
                transferredText: fetchedFormatted,
                remainingText: nil,
                percentText: nil,
                cliBarLine: cliBar,
                isFinished: phaseFinished
            )
        }

        guard let totalBytes = ByteSize.parse(totalRaw), totalBytes > 0 else {
            let cliBar = "\(asciiBar(fraction: nil)) \(label) · \(fetchedFormatted)"
            return DownloadProgress(
                label: label,
                fraction: nil,
                transferredText: fetchedFormatted,
                remainingText: nil,
                percentText: nil,
                cliBarLine: cliBar,
                isFinished: phaseFinished
            )
        }

        let totalFormatted = ByteSize.format(totalBytes)
        let rawFraction = fetchedBytes / totalBytes
        let fraction = phaseFinished ? 1.0 : min(max(rawFraction, 0), 1)
        let percent = Int((fraction * 100).rounded())
        let remainingBytes = max(totalBytes - fetchedBytes, 0)
        let transferredText = "\(fetchedFormatted) / \(totalFormatted)"
        let percentText = "\(percent)%"
        let remainingText = (phaseFinished || remainingBytes <= 0) ? nil : "faltan \(ByteSize.format(remainingBytes))"

        let cliBar = buildCLIBarLine(
            fraction: fraction,
            percentText: percentText,
            label: label,
            transferredText: transferredText,
            remainingText: remainingText
        )

        return DownloadProgress(
            label: label,
            fraction: fraction,
            transferredText: transferredText,
            remainingText: remainingText,
            percentText: percentText,
            cliBarLine: cliBar,
            isFinished: phaseFinished
        )
    }

    private static func parseCurlProgressBar(_ line: String) -> DownloadProgress? {
        let pattern = #"^[#\s=O-]*([0-9]+(?:\.[0-9]+)?)\s*%$"#
        guard let match = firstMatch(pattern, in: line), match.count == 2,
              let rawPercent = Double(match[1]) else {
            return nil
        }

        let clampedPercent = min(max(rawPercent, 0), 100)
        let fraction = clampedPercent / 100.0
        let roundedPercent = Int(clampedPercent.rounded())
        let percentText = "\(roundedPercent)%"
        let isFinished = clampedPercent >= 100.0
        let remainingPercent = max(0, 100 - roundedPercent)
        let remainingText = isFinished ? nil : "falta \(remainingPercent)%"
        let label = "Descargando"
        let cliBar = buildCLIBarLine(
            fraction: fraction,
            percentText: percentText,
            label: label,
            transferredText: nil,
            remainingText: remainingText
        )

        return DownloadProgress(
            label: label,
            fraction: fraction,
            transferredText: nil,
            remainingText: remainingText,
            percentText: percentText,
            cliBarLine: cliBar,
            isFinished: isFinished
        )
    }

    private static func parseCurlMeter(_ line: String) -> DownloadProgress? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 12 else { return nil }
        guard let totalPercent = Int(parts[0]), (0...100).contains(totalPercent),
              let receivedPercent = Int(parts[2]), (0...100).contains(receivedPercent),
              let xferPercent = Int(parts[4]), (0...100).contains(xferPercent),
              isCurlTimeToken(parts[8]),
              isCurlTimeToken(parts[9]),
              isCurlTimeToken(parts[10]),
              let totalBytes = ByteSize.parseCurl(parts[1]),
              let receivedBytes = ByteSize.parseCurl(parts[3])
        else {
            return nil
        }

        if totalBytes <= 0 {
            return DownloadProgress(label: "Conectando…", fraction: nil, cliBarLine: "")
        }

        let isFinished = totalPercent >= 100 || receivedBytes >= totalBytes
        let fraction = isFinished ? 1.0 : min(max(Double(totalPercent) / 100.0, 0), 1)
        let percentText = "\(isFinished ? 100 : totalPercent)%"
        let transferredText = "\(ByteSize.format(receivedBytes)) / \(ByteSize.format(totalBytes))"
        let remainingBytes = max(totalBytes - receivedBytes, 0)

        let remainingText: String?
        if isFinished {
            remainingText = nil
        } else {
            let sizePart = "faltan \(ByteSize.format(remainingBytes))"
            remainingText = parts[10] == "--:--:--" ? sizePart : "\(sizePart) · \(parts[10])"
        }

        let label = "Descargando"
        let cliBar = buildCLIBarLine(
            fraction: fraction,
            percentText: percentText,
            label: label,
            transferredText: transferredText,
            remainingText: remainingText
        )

        return DownloadProgress(
            label: label,
            fraction: fraction,
            transferredText: transferredText,
            remainingText: remainingText,
            percentText: percentText,
            cliBarLine: cliBar,
            isFinished: isFinished
        )
    }

    private static func parsePnpmDownload(_ line: String) -> DownloadProgress? {
        let pattern = #"^Downloading\s+(.+?):\s+([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|B))\s*/\s*([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|B))$"#
        guard let match = firstMatch(pattern, in: line), match.count == 4 else {
            return nil
        }

        let label = match[1].trimmingCharacters(in: .whitespaces)
        guard let fetchedBytes = ByteSize.parse(match[2]),
              let totalBytes = ByteSize.parse(match[3]),
              totalBytes > 0 else {
            return nil
        }

        let isFinished = fetchedBytes >= totalBytes
        let fraction = isFinished ? 1.0 : min(max(fetchedBytes / totalBytes, 0), 1)
        let percent = Int((fraction * 100).rounded())
        let percentText = "\(percent)%"
        let transferredText = "\(ByteSize.format(fetchedBytes)) / \(ByteSize.format(totalBytes))"
        let remainingBytes = max(totalBytes - fetchedBytes, 0)
        let remainingText = (isFinished || remainingBytes <= 0) ? nil : "faltan \(ByteSize.format(remainingBytes))"
        let cliBar = buildCLIBarLine(
            fraction: fraction,
            percentText: percentText,
            label: label,
            transferredText: transferredText,
            remainingText: remainingText
        )

        return DownloadProgress(
            label: label,
            fraction: fraction,
            transferredText: transferredText,
            remainingText: remainingText,
            percentText: percentText,
            cliBarLine: cliBar,
            isFinished: isFinished
        )
    }

    private static func parsePnpmProgress(_ line: String) -> DownloadProgress? {
        let pattern = #"^Progress:\s+resolved\s+(\d+),\s+reused\s+(\d+),\s+downloaded\s+(\d+),\s+added\s+(\d+)(,\s*done)?$"#
        guard let match = firstMatch(pattern, in: line), match.count >= 5,
              let resolved = Int(match[1]),
              let reused = Int(match[2]),
              let downloaded = Int(match[3]),
              let added = Int(match[4]) else {
            return nil
        }

        let isDone = match.count > 5 && !match[5].isEmpty
        let label = "Dependencias pnpm"

        if resolved <= 0 {
            return DownloadProgress(label: label, fraction: isDone ? 1.0 : nil, cliBarLine: "", isFinished: isDone)
        }

        let completed = min(reused + downloaded, resolved)
        let fraction = isDone ? 1.0 : min(max(Double(completed) / Double(resolved), 0), 1)
        let percent = Int((fraction * 100).rounded())
        let percentText = "\(percent)%"
        let transferredText = "\(completed) / \(resolved) paquetes"
        let remainingCount = max(0, resolved - completed)
        let remainingText = (isDone || remainingCount == 0) ? nil : "faltan \(remainingCount)"

        let detail = "\(completed)/\(resolved) paquetes (\(downloaded) descargados, \(reused) en caché, \(added) añadidos)"
        let cliBar = buildCLIBarLine(
            fraction: fraction,
            percentText: percentText,
            label: "pnpm",
            transferredText: detail,
            remainingText: remainingText
        )

        return DownloadProgress(
            label: label,
            fraction: fraction,
            transferredText: transferredText,
            remainingText: remainingText,
            percentText: percentText,
            cliBarLine: cliBar,
            isFinished: isDone
        )
    }

    private static func parseNpmHttpFetch(_ line: String) -> DownloadProgress? {
        let pattern = #"^npm\s+http\s+fetch\s+\S+\s+\d+\s+(https?://\S+)"#
        guard let match = firstMatch(pattern, in: line), match.count == 2,
              let url = URL(string: match[1]) else {
            return nil
        }

        var name = url.lastPathComponent
        if name.hasSuffix(".tgz") {
            name = String(name.dropLast(4))
        }
        if name.isEmpty || name == "-" {
            name = url.pathComponents.last(where: { $0 != "/" && $0 != "-" }) ?? "paquete"
        }

        return DownloadProgress(
            label: "Descargando \(name)…",
            fraction: nil,
            cliBarLine: ""
        )
    }

    private static func parseHomebrewHeading(_ line: String) -> DownloadProgress? {
        guard line.hasPrefix("==> ") else { return nil }
        let body = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        guard homebrewPhasePrefixes.contains(where: { body.hasPrefix($0) }) else {
            return nil
        }
        return DownloadProgress(label: body, fraction: nil, cliBarLine: "")
    }

    private static func buildCLIBarLine(
        fraction: Double,
        percentText: String,
        label: String,
        transferredText: String?,
        remainingText: String?
    ) -> String {
        var parts = ["\(asciiBar(fraction: fraction)) \(percentText)", label]
        if let transferredText, !transferredText.isEmpty {
            if let remainingText, !remainingText.isEmpty {
                parts.append("\(transferredText) (\(remainingText))")
            } else {
                parts.append(transferredText)
            }
        } else if let remainingText, !remainingText.isEmpty {
            parts.append("(\(remainingText))")
        }
        return parts.joined(separator: " · ")
    }

    private static func isCurlTimeToken(_ token: String) -> Bool {
        if token == "--:--:--" { return true }
        return token.range(of: #"^\d+:\d{2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { idx in
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}

private enum ByteSize {
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]i?B|B)$"#),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              let numRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed),
              let value = Double(trimmed[numRange]) else {
            return nil
        }

        let multiplier: Double
        switch trimmed[unitRange] {
        case "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        case "KiB": multiplier = 1_024
        case "MiB": multiplier = 1_048_576
        case "GiB": multiplier = 1_073_741_824
        case "TiB": multiplier = 1_099_511_627_776
        default: return nil
        }
        return value * multiplier
    }

    static func parseCurl(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) {
            return value
        }
        guard let last = trimmed.last,
              let value = Double(trimmed.dropLast()) else {
            return nil
        }
        switch last {
        case "k", "K": return value * 1_024
        case "m", "M": return value * 1_048_576
        case "g", "G": return value * 1_073_741_824
        case "t", "T": return value * 1_099_511_627_776
        default: return nil
        }
    }

    static func format(_ bytes: Double) -> String {
        let value = max(bytes, 0)
        let posix = Locale(identifier: "en_US_POSIX")
        if value < 1_000 {
            return "\(Int(value.rounded())) B"
        }
        if value < 1_000_000 {
            return String(format: "%.1f KB", locale: posix, value / 1_000)
        }
        if value < 1_000_000_000 {
            return String(format: "%.1f MB", locale: posix, value / 1_000_000)
        }
        return String(format: "%.2f GB", locale: posix, value / 1_000_000_000)
    }
}
