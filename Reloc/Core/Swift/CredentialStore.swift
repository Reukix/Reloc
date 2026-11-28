import Foundation
import SwiftUI

public enum AppAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return L10n.tr("appearance.system")
        case .light: return L10n.tr("appearance.light")
        case .dark: return L10n.tr("appearance.dark")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum MapSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleNative
    case globalStreet
    case globalOSM
    case globalSatellite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleNative: return L10n.tr("map.source.apple")
        case .globalStreet: return L10n.tr("map.source.esri_street")
        case .globalOSM: return L10n.tr("map.source.osm")
        case .globalSatellite: return L10n.tr("map.source.esri_satellite")
        }
    }

    public var shortTitle: String {
        switch self {
        case .appleNative: return L10n.tr("map.source.apple.short")
        case .globalStreet: return L10n.tr("map.source.esri_street.short")
        case .globalOSM: return L10n.tr("map.source.osm.short")
        case .globalSatellite: return L10n.tr("map.source.esri_satellite.short")
        }
    }

    /// True when the tile source uses pure WGS-84 coordinates (no GCJ-02 shift in Mainland China).
    public var isPureWGS84: Bool {
        self != .appleNative
    }
}

public enum MapDisplayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case satellite
    case hybrid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return L10n.tr("map.style.standard")
        case .satellite: return L10n.tr("map.style.satellite")
        case .hybrid: return L10n.tr("map.style.hybrid")
        }
    }
}

public enum RefreshCountdownPreset: Int, CaseIterable, Codable, Identifiable, Sendable {
    case auto = 0
    case sec7 = 7
    case sec15 = 15
    case sec30 = 30

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .auto: return L10n.tr("settings.refresh_countdown.auto")
        case .sec7: return L10n.format("settings.refresh_countdown.seconds", 7)
        case .sec15: return L10n.format("settings.refresh_countdown.seconds", 15)
        case .sec30: return L10n.format("settings.refresh_countdown.seconds", 30)
        }
    }

    public func effectiveSeconds(isDistant: Bool) -> Int {
        switch self {
        case .auto:
            return isDistant ? 18 : 7
        case .sec7, .sec15, .sec30:
            return rawValue
        }
    }
}

public enum ProxyRuleFormat: String, CaseIterable, Identifiable, Sendable {
    case surge
    case shadowrocket
    case loon
    case clash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .surge: return "Surge (.sgmodule)"
        case .shadowrocket: return "Shadowrocket (.module)"
        case .loon: return "Loon (.plugin)"
        case .clash: return "Clash / Quantumult X"
        }
    }

    public var fileExtension: String {
        switch self {
        case .surge: return "sgmodule"
        case .shadowrocket: return "module"
        case .loon: return "plugin"
        case .clash: return "txt"
        }
    }

    /// Generates safe anti-snapback rules blocking only `gs-loc.apple.com` and `gs-loc-cn.apple.com`
    /// while preserving `ls.apple.com` so MapKit, search, and road routing remain intact.
    public var content: String {
        switch self {
        case .surge, .shadowrocket:
            return """
            #!name=Reloc Anti-Snapback
            #!desc=Block Apple Wi-Fi/Cell location verification domains (gs-loc) to stabilize long-distance virtual GPS without breaking Apple Maps.

            [Rule]
            DOMAIN,gs-loc.apple.com,REJECT
            DOMAIN,gs-loc-cn.apple.com,REJECT
            """
        case .loon:
            return """
            #!name=Reloc Anti-Snapback
            #!desc=Block Apple Wi-Fi/Cell location verification domains (gs-loc) to stabilize long-distance virtual GPS without breaking Apple Maps.

            [Rule]
            DOMAIN,gs-loc.apple.com,REJECT
            DOMAIN,gs-loc-cn.apple.com,REJECT
            """
        case .clash:
            return """
            # Reloc Anti-Snapback (Safe Subset - preserves Apple Maps)
            # Clash / Stash / Mihomo:
            - DOMAIN,gs-loc.apple.com,REJECT
            - DOMAIN,gs-loc-cn.apple.com,REJECT

            # Quantumult X:
            host, gs-loc.apple.com, reject
            host, gs-loc-cn.apple.com, reject
            """
        }
    }

    public func writeTemporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelocProxyRules", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Reloc_AntiSnapback.\(fileExtension)")
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}

public struct FavoriteLocation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String?
    public var group: String?
    public var note: String?
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    private enum CodingKeys: String, CodingKey {
        case id, name, subtitle, group, note, latitude, longitude, altitude
    }

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String? = nil,
        group: String? = nil,
        note: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        let cleanGroup = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.group = (cleanGroup?.isEmpty == false) ? cleanGroup : nil
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (cleanNote?.isEmpty == false) ? cleanNote : nil
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        let rawGroup = try c.decodeIfPresent(String.self, forKey: .group)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.group = (rawGroup?.isEmpty == false) ? rawGroup : nil
        let rawNote = try c.decodeIfPresent(String.self, forKey: .note)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (rawNote?.isEmpty == false) ? rawNote : nil
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
        self.altitude = try c.decodeIfPresent(Double.self, forKey: .altitude) ?? 10.0
    }
}

public struct RecentLocation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String?
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var usedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0,
        usedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.usedAt = usedAt
    }
}

public struct CachedRealLocationRecord: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var savedAt: Date

    public init(latitude: Double, longitude: Double, altitude: Double, savedAt: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.savedAt = savedAt
    }
}

public struct InterruptedSessionRecord: Codable, Equatable, Sendable {
    public var placeName: String
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var savedAt: Date

    public init(
        placeName: String,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        savedAt: Date = Date()
    ) {
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.savedAt = savedAt
    }
}

/// Persists location preferences, favorites, history and recovery snapshots.
public final class CredentialStore {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let interval = "reloc.interval"
        static let duration = "reloc.duration"
        static let gcj02Correction = "reloc.gcj02Correction"
        static let microJitter = "reloc.microJitter"
        static let backgroundLocationIndicator = "reloc.backgroundLocationIndicator"
        static let appearance = "reloc.appearance"
        static let language = L10n.languageDefaultsKey
        static let mapStyle = "reloc.mapStyle"
        static let mapSource = "reloc.mapSource"
        static let favorites = "reloc.favorites"
        static let recents = "reloc.recents"
        static let savedRoutes = "reloc.savedRoutes"
        static let routePreset = "reloc.routePreset"
        static let routeSpeed = "reloc.routeSpeed"
        static let routeLoopMode = "reloc.routeLoopMode"
        static let routeRealisticMotion = "reloc.routeRealisticMotion"
        static let routeStopGoalKind = "reloc.routeStopGoalKind"
        static let routeTargetDistanceKm = "reloc.routeTargetDistanceKm"
        static let routeTargetLaps = "reloc.routeTargetLaps"
        static let routeBriefStops = "reloc.routeBriefStops"
        static let joystickSpeed = "reloc.joystickSpeed"
        static let refreshCountdownPreset = "reloc.refreshCountdownPreset"
        static let interruptedSession = "reloc.interruptedSession"
        static let lastRealLocation = "reloc.lastRealLocation"
        static let lastLatitude = "reloc.lastLat"
        static let lastLongitude = "reloc.lastLon"
        static let lastAltitude = "reloc.lastAlt"
    }

    public var intervalSeconds: Double {
        get {
            let v = defaults.double(forKey: Keys.interval)
            return v >= 1.0 ? v : 1.0
        }
        set { defaults.set(max(1.0, newValue), forKey: Keys.interval) }
    }

    public var durationSeconds: Double {
        get { max(0.0, defaults.double(forKey: Keys.duration)) }
        set { defaults.set(max(0.0, newValue), forKey: Keys.duration) }
    }

    public var gcj02CorrectionEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.gcj02Correction) == nil { return true }
            return defaults.bool(forKey: Keys.gcj02Correction)
        }
        set { defaults.set(newValue, forKey: Keys.gcj02Correction) }
    }

    public var microJitterEnabled: Bool {
        get { defaults.bool(forKey: Keys.microJitter) }
        set { defaults.set(newValue, forKey: Keys.microJitter) }
    }

    public var backgroundLocationIndicatorEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.backgroundLocationIndicator) == nil { return true }
            return defaults.bool(forKey: Keys.backgroundLocationIndicator)
        }
        set { defaults.set(newValue, forKey: Keys.backgroundLocationIndicator) }
    }

    public var appearanceMode: AppAppearanceMode {
        get { defaults.string(forKey: Keys.appearance).flatMap(AppAppearanceMode.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    public var appLanguage: AppLanguage {
        get { defaults.string(forKey: Keys.language).flatMap(AppLanguage.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.language) }
    }

    public var mapStyle: MapDisplayStyle {
        get { defaults.string(forKey: Keys.mapStyle).flatMap(MapDisplayStyle.init) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: Keys.mapStyle) }
    }

    public var mapSource: MapSource {
        get { defaults.string(forKey: Keys.mapSource).flatMap(MapSource.init) ?? .appleNative }
        set { defaults.set(newValue.rawValue, forKey: Keys.mapSource) }
    }

    public var lastTargetLocation: TargetLocation {
        get {
            if defaults.object(forKey: Keys.lastLatitude) == nil {
                return TargetLocation(latitude: 37.334606, longitude: -122.009102, altitude: 20.0)
            }
            return TargetLocation(
                latitude: defaults.double(forKey: Keys.lastLatitude),
                longitude: defaults.double(forKey: Keys.lastLongitude),
                altitude: defaults.object(forKey: Keys.lastAltitude) != nil ? defaults.double(forKey: Keys.lastAltitude) : 10.0
            )
        }
        set {
            defaults.set(newValue.latitude, forKey: Keys.lastLatitude)
            defaults.set(newValue.longitude, forKey: Keys.lastLongitude)
            defaults.set(newValue.altitude, forKey: Keys.lastAltitude)
        }
    }

    // MARK: - Trajectory Settings & Saved Routes

    public var routePreset: RouteTransportPreset {
        get { defaults.string(forKey: Keys.routePreset).flatMap(RouteTransportPreset.init) ?? .walking }
        set { defaults.set(newValue.rawValue, forKey: Keys.routePreset) }
    }

    public var routeSpeedMps: Double {
        get {
            let v = defaults.double(forKey: Keys.routeSpeed)
            return v >= 0.3 ? v : routePreset.defaultSpeedMps
        }
        set { defaults.set(max(0.3, newValue), forKey: Keys.routeSpeed) }
    }

    public var routeLoopMode: RouteLoopMode {
        get { defaults.string(forKey: Keys.routeLoopMode).flatMap(RouteLoopMode.init) ?? .once }
        set { defaults.set(newValue.rawValue, forKey: Keys.routeLoopMode) }
    }

    public var routeRealisticMotionEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.routeRealisticMotion) == nil { return true }
            return defaults.bool(forKey: Keys.routeRealisticMotion)
        }
        set { defaults.set(newValue, forKey: Keys.routeRealisticMotion) }
    }

    public var routeStopGoalKind: RouteStopGoalKind {
        get { defaults.string(forKey: Keys.routeStopGoalKind).flatMap(RouteStopGoalKind.init) ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Keys.routeStopGoalKind) }
    }

    public var routeTargetDistanceKm: Double {
        get {
            let v = defaults.double(forKey: Keys.routeTargetDistanceKm)
            return v >= 0.2 ? min(200.0, v) : 3.0
        }
        set { defaults.set(min(200.0, max(0.2, newValue)), forKey: Keys.routeTargetDistanceKm) }
    }

    public var routeTargetLaps: Int {
        get {
            let v = defaults.integer(forKey: Keys.routeTargetLaps)
            return v >= 1 ? min(200, v) : 5
        }
        set { defaults.set(min(200, max(1, newValue)), forKey: Keys.routeTargetLaps) }
    }

    public var routeBriefStopsEnabled: Bool {
        get { defaults.bool(forKey: Keys.routeBriefStops) }
        set { defaults.set(newValue, forKey: Keys.routeBriefStops) }
    }

    public var joystickSpeedMps: Double {
        get {
            let v = defaults.double(forKey: Keys.joystickSpeed)
            return v >= 0.3 ? min(35.0, v) : RouteTransportPreset.walking.defaultSpeedMps
        }
        set { defaults.set(min(35.0, max(0.3, newValue)), forKey: Keys.joystickSpeed) }
    }

    public var refreshCountdownPreset: RefreshCountdownPreset {
        get {
            guard defaults.object(forKey: Keys.refreshCountdownPreset) != nil else { return .auto }
            return RefreshCountdownPreset(rawValue: defaults.integer(forKey: Keys.refreshCountdownPreset)) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.refreshCountdownPreset) }
    }

    public func loadSavedRoutes() -> [SavedRoute] {
        guard let data = defaults.data(forKey: Keys.savedRoutes),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveSavedRoutes(_ routes: [SavedRoute]) {
        if let encoded = try? JSONEncoder().encode(routes) {
            defaults.set(encoded, forKey: Keys.savedRoutes)
        }
    }

    // MARK: - Favorites, Recents (max 30), and Interrupted Session Recovery

    private static let starterAppleParkID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private static let starterTokyoStationID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private static let starterTaipei101ID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!

    public func loadFavorites() -> [FavoriteLocation] {
        guard let data = defaults.data(forKey: Keys.favorites),
              let decoded = try? JSONDecoder().decode([FavoriteLocation].self, from: data) else {
            return [
                FavoriteLocation(
                    id: Self.starterAppleParkID,
                    name: "Apple Park",
                    subtitle: "Cupertino, CA",
                    latitude: 37.334606,
                    longitude: -122.009102,
                    altitude: 20.0
                ),
                FavoriteLocation(
                    id: Self.starterTokyoStationID,
                    name: L10n.tr("favorite.tokyo_station.name"),
                    subtitle: L10n.tr("favorite.tokyo_station.subtitle"),
                    latitude: 35.681236,
                    longitude: 139.767125,
                    altitude: 10.0
                ),
                FavoriteLocation(
                    id: Self.starterTaipei101ID,
                    name: L10n.tr("favorite.taipei_101.name"),
                    subtitle: L10n.tr("favorite.taipei_101.subtitle"),
                    latitude: 25.033964,
                    longitude: 121.564468,
                    altitude: 12.0
                ),
            ]
        }
        return decoded
    }

    public func saveFavorites(_ favorites: [FavoriteLocation]) {
        if let encoded = try? JSONEncoder().encode(favorites) {
            defaults.set(encoded, forKey: Keys.favorites)
        }
    }

    public func loadRecents() -> [RecentLocation] {
        guard let data = defaults.data(forKey: Keys.recents),
              let decoded = try? JSONDecoder().decode([RecentLocation].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveRecents(_ recents: [RecentLocation]) {
        let trimmed = Array(recents.prefix(30))
        if let encoded = try? JSONEncoder().encode(trimmed) {
            defaults.set(encoded, forKey: Keys.recents)
        }
    }

    public func loadInterruptedSession() -> InterruptedSessionRecord? {
        guard let data = defaults.data(forKey: Keys.interruptedSession) else { return nil }
        return try? JSONDecoder().decode(InterruptedSessionRecord.self, from: data)
    }

    public func saveInterruptedSession(_ record: InterruptedSessionRecord?) {
        guard let record else {
            defaults.removeObject(forKey: Keys.interruptedSession)
            return
        }
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Keys.interruptedSession)
        }
    }

    public func loadCachedRealLocation(maxAgeSeconds: TimeInterval = 24 * 3600) -> TargetLocation? {
        guard let data = defaults.data(forKey: Keys.lastRealLocation),
              let rec = try? JSONDecoder().decode(CachedRealLocationRecord.self, from: data),
              rec.latitude.isFinite, rec.longitude.isFinite,
              abs(rec.savedAt.timeIntervalSinceNow) <= maxAgeSeconds else {
            return nil
        }
        return TargetLocation(latitude: rec.latitude, longitude: rec.longitude, altitude: rec.altitude)
    }

    public func saveCachedRealLocation(_ location: TargetLocation) {
        guard location.latitude.isFinite, location.longitude.isFinite else { return }
        let rec = CachedRealLocationRecord(
            latitude: location.latitude,
            longitude: location.longitude,
            altitude: location.altitude.isFinite ? location.altitude : 10.0
        )
        if let data = try? JSONEncoder().encode(rec) {
            defaults.set(data, forKey: Keys.lastRealLocation)
        }
    }

    // MARK: - Internal Bundled MFi Signer

    public func loadBundledMFiSigner() -> RLMFiSigner? {
        let bundle = Bundle.main
        guard let certURL = bundle.url(forResource: "certificate", withExtension: "p7b", subdirectory: "MFi")
                ?? bundle.url(forResource: "certificate", withExtension: "p7b"),
              let keyURL = bundle.url(forResource: "identity", withExtension: "pk8", subdirectory: "MFi")
                ?? bundle.url(forResource: "identity", withExtension: "pk8"),
              let certData = try? Data(contentsOf: certURL),
              let keyData = try? Data(contentsOf: keyURL) else {
            return nil
        }
        return try? RLMFiSigner(certificateData: certData, privateKeyData: keyData)
    }
}

// MARK: - Reloc Favorites & Routes Backup Archive (JSON)

public enum RelocBackupError: LocalizedError, Sendable {
    case unreadableFile
    case fileTooLarge
    case invalidFormat(String)
    case emptyArchive

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return L10n.tr("backup.error.unreadable")
        case .fileTooLarge:
            return L10n.tr("backup.error.too_large")
        case .invalidFormat(let detail):
            return L10n.format("backup.error.invalid_format", detail)
        case .emptyArchive:
            return L10n.tr("backup.error.empty")
        }
    }
}

public struct RelocBackupArchive: Codable, Equatable, Sendable {
    public static let currentSchema = "reloc.backup"
    public static let currentVersion = 1

    public var schema: String
    public var version: Int
    public var exportedAt: Date
    public var favorites: [FavoriteLocation]
    public var savedRoutes: [SavedRoute]

    public init(
        schema: String = RelocBackupArchive.currentSchema,
        version: Int = RelocBackupArchive.currentVersion,
        exportedAt: Date = Date(),
        favorites: [FavoriteLocation],
        savedRoutes: [SavedRoute]
    ) {
        self.schema = schema
        self.version = version
        self.exportedAt = exportedAt
        self.favorites = favorites
        self.savedRoutes = savedRoutes
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, exportedAt, favorites, savedRoutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? Self.currentSchema
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        self.favorites = try c.decodeIfPresent([FavoriteLocation].self, forKey: .favorites) ?? []
        self.savedRoutes = try c.decodeIfPresent([SavedRoute].self, forKey: .savedRoutes) ?? []
    }
}

public struct RelocBackupImportSummary: Equatable, Sendable {
    public let addedFavorites: Int
    public let updatedFavorites: Int
    public let addedRoutes: Int
    public let updatedRoutes: Int
}

public enum RelocBackupCodec {
    public static let maxImportBytes = 20 * 1024 * 1024 // 20 MB

    public static func encode(
        favorites: [FavoriteLocation],
        savedRoutes: [SavedRoute],
        exportedAt: Date = Date()
    ) throws -> Data {
        let archive = RelocBackupArchive(
            exportedAt: exportedAt,
            favorites: favorites,
            savedRoutes: savedRoutes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    public static func decode(data: Data) throws -> RelocBackupArchive {
        guard !data.isEmpty else { throw RelocBackupError.unreadableFile }
        guard data.count <= maxImportBytes else { throw RelocBackupError.fileTooLarge }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let raw: RelocBackupArchive
        do {
            raw = try decoder.decode(RelocBackupArchive.self, from: data)
        } catch {
            // Fallback for standard Date numeric timestamps if edited externally.
            let fallbackDecoder = JSONDecoder()
            do {
                raw = try fallbackDecoder.decode(RelocBackupArchive.self, from: data)
            } catch {
                throw RelocBackupError.invalidFormat(error.localizedDescription)
            }
        }

        let validFavorites: [FavoriteLocation] = raw.favorites.compactMap { fav in
            let name = fav.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  fav.latitude.isFinite, fav.longitude.isFinite,
                  (-90.0...90.0).contains(fav.latitude),
                  (-180.0...180.0).contains(fav.longitude) else {
                return nil
            }
            let alt = fav.altitude.isFinite ? min(50_000.0, max(-500.0, fav.altitude)) : 10.0
            return FavoriteLocation(
                id: fav.id,
                name: name,
                subtitle: fav.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                group: fav.group,
                note: fav.note,
                latitude: fav.latitude,
                longitude: fav.longitude,
                altitude: alt
            )
        }

        let validRoutes: [SavedRoute] = raw.savedRoutes.compactMap { route in
            let name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPoints: [RoutePoint] = route.points.compactMap { pt in
                guard pt.latitude.isFinite, pt.longitude.isFinite,
                      (-90.0...90.0).contains(pt.latitude),
                      (-180.0...180.0).contains(pt.longitude) else {
                    return nil
                }
                let alt = pt.altitude.isFinite ? min(50_000.0, max(-500.0, pt.altitude)) : 10.0
                return RoutePoint(latitude: pt.latitude, longitude: pt.longitude, altitude: alt)
            }
            guard !name.isEmpty, cleanPoints.count >= 2 else { return nil }
            let cleanWaypoints: [RouteWaypoint] = route.waypoints.compactMap { wp in
                guard wp.latitude.isFinite, wp.longitude.isFinite,
                      (-90.0...90.0).contains(wp.latitude),
                      (-180.0...180.0).contains(wp.longitude) else {
                    return nil
                }
                let alt = wp.altitude.isFinite ? min(50_000.0, max(-500.0, wp.altitude)) : 10.0
                return RouteWaypoint(
                    id: wp.id,
                    name: wp.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    latitude: wp.latitude,
                    longitude: wp.longitude,
                    altitude: alt
                )
            }
            let dist = RouteGeometry.totalDistance(of: cleanPoints)
            guard dist >= 1.0 else { return nil }
            return SavedRoute(
                id: route.id,
                name: name,
                waypoints: cleanWaypoints,
                points: cleanPoints,
                preset: route.preset,
                speedMetersPerSecond: max(0.3, min(50.0, route.speedMetersPerSecond.isFinite ? route.speedMetersPerSecond : route.preset.defaultSpeedMps)),
                loopMode: route.loopMode,
                totalDistanceMeters: dist,
                isFreehand: route.isFreehand,
                targetDistanceMeters: route.targetDistanceMeters.flatMap { ($0.isFinite && $0 >= 10.0) ? $0 : nil },
                targetLaps: route.targetLaps.flatMap { $0 >= 1 ? $0 : nil },
                createdAt: route.createdAt
            )
        }

        guard !validFavorites.isEmpty || !validRoutes.isEmpty else {
            throw RelocBackupError.emptyArchive
        }

        return RelocBackupArchive(
            schema: raw.schema,
            version: raw.version,
            exportedAt: raw.exportedAt,
            favorites: validFavorites,
            savedRoutes: validRoutes
        )
    }

    public static func decode(fileURL: URL) throws -> RelocBackupArchive {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = (attrs?[.size] as? NSNumber)?.intValue, size > maxImportBytes {
            throw RelocBackupError.fileTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw RelocBackupError.unreadableFile
        }
        return try decode(data: data)
    }

    public static func writeTemporaryBackupFile(data: Data, date: Date = Date()) throws -> URL {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd_HHmm"
        let filename = "Reloc_Backup_\(df.string(from: date)).json"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelocBackupExport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
