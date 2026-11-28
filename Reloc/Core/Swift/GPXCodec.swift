import CoreLocation
import Foundation
import UniformTypeIdentifiers

public extension UTType {
    /// GPX (GPS Exchange Format) Uniform Type Identifier with XML fallback so Files/cloud providers
    /// never gray out `.gpx` documents.
    static var relocGPX: UTType {
        UTType(filenameExtension: "gpx")
            ?? UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    }
}

public enum GPXCodecError: LocalizedError, Sendable {
    case unreadableFile
    case fileTooLarge
    case invalidXML(String)
    case noCoordinates

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return L10n.tr("gpx.error.unreadable")
        case .fileTooLarge:
            return L10n.tr("gpx.error.too_large")
        case .invalidXML(let detail):
            return L10n.format("gpx.error.invalid_xml", detail)
        case .noCoordinates:
            return L10n.tr("gpx.error.no_coordinates")
        }
    }
}

public struct GPXImportResult: Sendable {
    public let name: String?
    public let points: [RoutePoint]
    public let waypoints: [RouteWaypoint]
    public let hasElevation: Bool
    public let isClosedLoop: Bool

    public var isSinglePoint: Bool {
        points.count == 1
    }
}

/// Standards-compliant GPX 1.0 / 1.1 parser and exporter (pure WGS-84, zero third-party dependencies).
public enum GPXCodec {
    public static let maxImportBytes = 20 * 1024 * 1024 // 20 MB safety guard
    private static let maxRouteVertices = 2000

    // MARK: - Import (Parse GPX 1.0 / 1.1)

    public static func parse(
        data: Data,
        fallbackName: String? = nil,
        defaultAltitude: Double = 10.0
    ) throws -> GPXImportResult {
        guard !data.isEmpty else { throw GPXCodecError.unreadableFile }
        guard data.count <= maxImportBytes else { throw GPXCodecError.fileTooLarge }

        let delegate = GPXParserDelegate(defaultAltitude: defaultAltitude)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "parse error"
            throw GPXCodecError.invalidXML(reason)
        }

        // Priority: track points (<trkpt>) > route points (<rtept>) > waypoints (<wpt>).
        let rawPoints: [ParsedPoint]
        let preferredName: String?
        if delegate.trackPoints.count >= 2 {
            rawPoints = delegate.trackPoints
            preferredName = delegate.trackName ?? delegate.metadataName
        } else if delegate.routePoints.count >= 2 {
            rawPoints = delegate.routePoints
            preferredName = delegate.routeName ?? delegate.metadataName
        } else if delegate.waypoints.count >= 2 {
            rawPoints = delegate.waypoints
            preferredName = delegate.metadataName
        } else if let single = delegate.trackPoints.first ?? delegate.routePoints.first ?? delegate.waypoints.first {
            let pt = RoutePoint(latitude: single.lat, longitude: single.lon, altitude: single.ele ?? defaultAltitude)
            let name = single.name ?? delegate.trackName ?? delegate.routeName ?? delegate.metadataName ?? fallbackName
            let wp = RouteWaypoint(name: name ?? String(format: "%.5f, %.5f", pt.latitude, pt.longitude), latitude: pt.latitude, longitude: pt.longitude, altitude: pt.altitude)
            return GPXImportResult(
                name: cleanName(name),
                points: [pt],
                waypoints: [wp],
                hasElevation: single.ele != nil,
                isClosedLoop: false
            )
        } else {
            throw GPXCodecError.noCoordinates
        }

        let hasElevation = rawPoints.contains(where: { $0.ele != nil })
        var cleaned: [RoutePoint] = []
        cleaned.reserveCapacity(rawPoints.count)
        for item in rawPoints {
            let pt = RoutePoint(
                latitude: item.lat,
                longitude: item.lon,
                altitude: item.ele ?? defaultAltitude
            )
            if let prev = cleaned.last, RouteGeometry.distanceMeters(from: prev, to: pt) < 0.5 {
                continue
            }
            cleaned.append(pt)
        }
        if let lastRaw = rawPoints.last {
            let endPt = RoutePoint(latitude: lastRaw.lat, longitude: lastRaw.lon, altitude: lastRaw.ele ?? defaultAltitude)
            if let prev = cleaned.last, RouteGeometry.distanceMeters(from: prev, to: endPt) >= 0.2 {
                cleaned.append(endPt)
            }
        }
        guard cleaned.count >= 2 else {
            throw GPXCodecError.noCoordinates
        }

        // Preserve exact geometry while capping very dense multi-hour 1 Hz logs to keep map rendering & storage crisp.
        if cleaned.count > maxRouteVertices {
            cleaned = simplifyDouglasPeucker(cleaned, toleranceMeters: 1.5, maxVertices: maxRouteVertices)
        }

        let totalDist = RouteGeometry.totalDistance(of: cleaned)
        guard totalDist >= 1.0 else {
            throw GPXCodecError.noCoordinates
        }
        let endGap = RouteGeometry.distanceMeters(from: cleaned.first!, to: cleaned.last!)
        let isClosedLoop = totalDist >= 60.0 && endGap <= min(50.0, max(25.0, totalDist * 0.08))

        let resolvedName = cleanName(preferredName) ?? cleanName(fallbackName)
        let namedWaypoints: [RouteWaypoint] = delegate.waypoints.prefix(32).map { w in
            RouteWaypoint(
                name: cleanName(w.name) ?? String(format: "%.5f, %.5f", w.lat, w.lon),
                latitude: w.lat,
                longitude: w.lon,
                altitude: w.ele ?? defaultAltitude
            )
        }

        return GPXImportResult(
            name: resolvedName,
            points: cleaned,
            waypoints: namedWaypoints,
            hasElevation: hasElevation,
            isClosedLoop: isClosedLoop
        )
    }

    public static func parse(
        fileURL: URL,
        defaultAltitude: Double = 10.0
    ) throws -> GPXImportResult {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = (attrs?[.size] as? NSNumber)?.intValue, size > maxImportBytes {
            throw GPXCodecError.fileTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw GPXCodecError.unreadableFile
        }
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        return try parse(data: data, fallbackName: fallbackName, defaultAltitude: defaultAltitude)
    }

    // MARK: - Export (Generate GPX 1.1)

    /// Exports a route (WGS-84 polyline + optional waypoints) into standards-compliant GPX 1.1 XML.
    public static func exportRoute(
        name: String,
        points: [RoutePoint],
        waypoints: [RouteWaypoint] = [],
        speedMetersPerSecond: Double = 3.0,
        startDate: Date = Date()
    ) -> Data {
        let safeName = cleanName(name) ?? "Reloc Route"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.reserveCapacity(points.count + waypoints.count + 16)
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<gpx version=\"1.1\" creator=\"Reloc\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">")
        lines.append("  <metadata>")
        lines.append("    <name>\(escapeXML(safeName))</name>")
        lines.append("    <time>\(iso.string(from: startDate))</time>")
        lines.append("  </metadata>")

        for wp in waypoints {
            let latStr = String(format: "%.6f", wp.latitude)
            let lonStr = String(format: "%.6f", wp.longitude)
            let altStr = String(format: "%.1f", clampAltitude(wp.altitude))
            lines.append("  <wpt lat=\"\(latStr)\" lon=\"\(lonStr)\">")
            lines.append("    <ele>\(altStr)</ele>")
            lines.append("    <name>\(escapeXML(wp.name))</name>")
            lines.append("  </wpt>")
        }

        if !points.isEmpty {
            lines.append("  <trk>")
            lines.append("    <name>\(escapeXML(safeName))</name>")
            lines.append("    <trkseg>")
            let safeSpeed = max(0.3, speedMetersPerSecond.isFinite ? speedMetersPerSecond : 3.0)
            var elapsed: TimeInterval = 0
            for idx in points.indices {
                let pt = points[idx]
                if idx > 0 {
                    let dist = RouteGeometry.distanceMeters(from: points[idx - 1], to: pt)
                    elapsed += dist / safeSpeed
                }
                let latStr = String(format: "%.6f", pt.latitude)
                let lonStr = String(format: "%.6f", pt.longitude)
                let altStr = String(format: "%.1f", clampAltitude(pt.altitude))
                let timeStr = iso.string(from: startDate.addingTimeInterval(elapsed))
                lines.append("      <trkpt lat=\"\(latStr)\" lon=\"\(lonStr)\"><ele>\(altStr)</ele><time>\(timeStr)</time></trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        lines.append("</gpx>")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Exports a single pinned WGS-84 location as a GPX 1.1 waypoint file.
    public static func exportWaypoint(
        name: String,
        location: TargetLocation,
        date: Date = Date()
    ) -> Data {
        let wp = RouteWaypoint(
            name: cleanName(name) ?? "Reloc Pin",
            latitude: location.latitude,
            longitude: location.longitude,
            altitude: location.altitude
        )
        return exportRoute(name: wp.name, points: [], waypoints: [wp], startDate: date)
    }

    /// Writes GPX data to a cleanly named temporary `.gpx` file suitable for iOS Share Sheet / AirDrop / Files.
    public static func writeTemporaryFile(name: String, data: Data) throws -> URL {
        let sanitized = sanitizeFilename(name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelocGPXExport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sanitized).gpx")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Helpers

    private static func clampAltitude(_ value: Double) -> Double {
        value.isFinite ? min(50_000.0, max(-500.0, value)) : 10.0
    }

    private static func cleanName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.components(separatedBy: illegal).joined(separator: "_")
        let collapsed = replaced.replacingOccurrences(of: " ", with: "_")
        let limited = String(collapsed.prefix(48))
        return limited.isEmpty ? "Reloc_Route" : limited
    }

    private static func simplifyDouglasPeucker(
        _ points: [RoutePoint],
        toleranceMeters: Double,
        maxVertices: Int
    ) -> [RoutePoint] {
        guard points.count > maxVertices else { return points }
        var tol = toleranceMeters
        var simplified = points
        for _ in 0..<6 {
            simplified = rdp(simplified, epsilonMeters: tol)
            if simplified.count <= maxVertices {
                return simplified
            }
            tol *= 1.8
        }
        // Final uniform stride guarantee preserving exact endpoints.
        let step = Double(simplified.count - 1) / Double(maxVertices - 1)
        var out: [RoutePoint] = []
        out.reserveCapacity(maxVertices)
        for i in 0..<(maxVertices - 1) {
            out.append(simplified[Int((Double(i) * step).rounded())])
        }
        out.append(simplified[simplified.count - 1])
        return out
    }

    private static func rdp(_ points: [RoutePoint], epsilonMeters: Double) -> [RoutePoint] {
        guard points.count >= 3 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end - start >= 2 else { continue }
            var maxDist = -1.0
            var splitIdx = start
            let a = points[start]
            let b = points[end]
            for i in (start + 1)..<end {
                let d = perpendicularDistanceMeters(point: points[i], lineStart: a, lineEnd: b)
                if d > maxDist {
                    maxDist = d
                    splitIdx = i
                }
            }
            if maxDist > epsilonMeters {
                keep[splitIdx] = true
                stack.append((start, splitIdx))
                stack.append((splitIdx, end))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    private static func perpendicularDistanceMeters(
        point p: RoutePoint,
        lineStart a: RoutePoint,
        lineEnd b: RoutePoint
    ) -> Double {
        let cosLat = max(0.01, cos(a.latitude * .pi / 180.0))
        let ax = 0.0, ay = 0.0
        let bx = (b.longitude - a.longitude) * 111_320.0 * cosLat
        let by = (b.latitude - a.latitude) * 111_320.0
        let px = (p.longitude - a.longitude) * 111_320.0 * cosLat
        let py = (p.latitude - a.latitude) * 111_320.0
        let dx = bx - ax
        let dy = by - ay
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-6 {
            return hypot(px, py)
        }
        let t = max(0.0, min(1.0, (px * dx + py * dy) / lenSq))
        let projX = ax + t * dx
        let projY = ay + t * dy
        return hypot(px - projX, py - projY)
    }

    // MARK: - XMLParser Delegate

    private struct ParsedPoint {
        let lat: Double
        let lon: Double
        var ele: Double?
        var name: String?
    }

    private final class GPXParserDelegate: NSObject, XMLParserDelegate {
        private let defaultAltitude: Double

        var metadataName: String?
        var trackName: String?
        var routeName: String?
        var trackPoints: [ParsedPoint] = []
        var routePoints: [ParsedPoint] = []
        var waypoints: [ParsedPoint] = []

        private var elementStack: [String] = []
        private var currentText = ""
        private var currentPoint: ParsedPoint?
        private var currentPointKind: String?

        init(defaultAltitude: Double) {
            self.defaultAltitude = defaultAltitude
        }

        private static func localName(_ elementName: String) -> String {
            if let colon = elementName.lastIndex(of: ":") {
                return String(elementName[elementName.index(after: colon)...]).lowercased()
            }
            return elementName.lowercased()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = Self.localName(elementName)
            elementStack.append(tag)
            currentText = ""

            if tag == "trkpt" || tag == "rtept" || tag == "wpt" {
                let latStr = attributeDict["lat"] ?? attributeDict["LAT"]
                let lonStr = attributeDict["lon"] ?? attributeDict["LON"]
                if let latStr, let lonStr,
                   let lat = Double(latStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                   let lon = Double(lonStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                   lat.isFinite, lon.isFinite,
                   (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
                    currentPoint = ParsedPoint(lat: lat, lon: lon, ele: nil, name: nil)
                    currentPointKind = tag
                } else {
                    currentPoint = nil
                    currentPointKind = nil
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let tag = Self.localName(elementName)
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            if tag == "ele", currentPoint != nil, let ele = Double(trimmed), ele.isFinite {
                currentPoint?.ele = min(50_000.0, max(-500.0, ele))
            } else if tag == "name", !trimmed.isEmpty {
                let parent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : ""
                if currentPoint != nil && (parent == "wpt" || parent == "trkpt" || parent == "rtept") {
                    currentPoint?.name = trimmed
                } else if parent == "trk", trackName == nil {
                    trackName = trimmed
                } else if parent == "rte", routeName == nil {
                    routeName = trimmed
                } else if parent == "metadata" || parent == "gpx", metadataName == nil {
                    metadataName = trimmed
                }
            } else if (tag == "trkpt" || tag == "rtept" || tag == "wpt"), let pt = currentPoint, currentPointKind == tag {
                switch tag {
                case "trkpt": trackPoints.append(pt)
                case "rtept": routePoints.append(pt)
                case "wpt": waypoints.append(pt)
                default: break
                }
                currentPoint = nil
                currentPointKind = nil
            }

            if !elementStack.isEmpty {
                elementStack.removeLast()
            }
            currentText = ""
        }
    }
}
