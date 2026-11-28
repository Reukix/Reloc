import AppIntents
import CoreLocation
import Foundation
import UIKit

private let systemLocationServicesPrefsURL = URL(string: "prefs:root=Privacy&path=LOCATION")!

// MARK: - Shortcut Errors

public enum RelocIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case mfiUnavailable
    case locationPermissionDenied
    case invalidCoordinate
    case routeNotFound
    case sessionFailed(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .mfiUnavailable:
            return "error.mfi_unavailable"
        case .locationPermissionDenied:
            return "intent.error.permission_denied"
        case .invalidCoordinate:
            return "intent.error.invalid_coordinate"
        case .routeNotFound:
            return "intent.error.route_not_found"
        case .sessionFailed(let detail):
            return "\(detail)"
        }
    }
}

// MARK: - Dynamic Entity: Saved Favorites

public struct FavoritePlaceEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "intent.entity.favorite")
    }

    public static var defaultQuery = FavoritePlaceQuery()

    public let id: String
    public let name: String
    public let subtitle: String
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "mappin.circle.fill")
        )
    }

    public init(favorite: FavoriteLocation) {
        self.id = favorite.id.uuidString
        self.name = favorite.name
        let coordText = favorite.subtitle ?? String(format: "%.5f, %.5f", favorite.latitude, favorite.longitude)
        if let grp = favorite.group, !grp.isEmpty {
            self.subtitle = "[\(grp)] \(coordText)"
        } else {
            self.subtitle = coordText
        }
        self.latitude = favorite.latitude
        self.longitude = favorite.longitude
        self.altitude = favorite.altitude
    }
}

public struct FavoritePlaceQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [FavoritePlaceEntity] {
        let all = CredentialStore().loadFavorites()
        var byLowerID: [String: FavoriteLocation] = [:]
        for fav in all {
            byLowerID[fav.id.uuidString.lowercased()] = fav
        }
        return identifiers.compactMap { rawID in
            if let hit = byLowerID[rawID.lowercased()] {
                return FavoritePlaceEntity(favorite: hit)
            }
            if let byName = all.first(where: { $0.name == rawID }) {
                return FavoritePlaceEntity(favorite: byName)
            }
            return nil
        }
    }

    public func entities(matching string: String) async throws -> [FavoritePlaceEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = CredentialStore().loadFavorites()
        guard !trimmed.isEmpty else { return all.map(FavoritePlaceEntity.init) }
        return all
            .filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    || ($0.group?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
            .map(FavoritePlaceEntity.init)
    }

    public func suggestedEntities() async throws -> [FavoritePlaceEntity] {
        CredentialStore().loadFavorites().map(FavoritePlaceEntity.init)
    }
}

// MARK: - Dynamic Entity: Saved Routes

public struct SavedRouteEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "intent.entity.route")
    }

    public static var defaultQuery = SavedRouteQuery()

    public let id: String
    public let name: String
    public let subtitle: String
    public let isFreehand: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: isFreehand ? "scribble.variable" : "point.filled.topleft.down.curvedto.point.bottomright.up")
        )
    }

    public init(route: SavedRoute) {
        self.id = route.id.uuidString
        self.name = route.name
        self.subtitle = "\(route.preset.title) · \(RouteGeometry.formatDistance(route.totalDistanceMeters))"
        self.isFreehand = route.isFreehand
    }
}

public struct SavedRouteQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [SavedRouteEntity] {
        let all = CredentialStore().loadSavedRoutes()
        var byLowerID: [String: SavedRoute] = [:]
        for r in all {
            byLowerID[r.id.uuidString.lowercased()] = r
        }
        return identifiers.compactMap { rawID in
            if let hit = byLowerID[rawID.lowercased()] {
                return SavedRouteEntity(route: hit)
            }
            if let byName = all.first(where: { $0.name == rawID }) {
                return SavedRouteEntity(route: byName)
            }
            return nil
        }
    }

    public func entities(matching string: String) async throws -> [SavedRouteEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = CredentialStore().loadSavedRoutes()
        guard !trimmed.isEmpty else { return all.map(SavedRouteEntity.init) }
        return all
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .map(SavedRouteEntity.init)
    }

    public func suggestedEntities() async throws -> [SavedRouteEntity] {
        CredentialStore().loadSavedRoutes().map(SavedRouteEntity.init)
    }
}

// MARK: - Shared Shortcut Handoff Helper

@MainActor
private func waitForForegroundWindow(timeoutSeconds: TimeInterval = 1.5) async {
    let activeDeadline = Date().addingTimeInterval(timeoutSeconds)
    while UIApplication.shared.applicationState != .active && Date() < activeDeadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

// MARK: - 1. Start Virtual Location (Favorite Place)

public struct StartFavoriteLocationIntent: AppIntent {
    public static var title: LocalizedStringResource = "intent.start_favorite.title"
    public static var description = IntentDescription("intent.start_favorite.desc")
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "intent.param.favorite", requestValueDialog: IntentDialog("intent.prompt.choose_favorite"))
    public var place: FavoritePlaceEntity

    @Parameter(title: "intent.param.auto_jump_settings", default: true)
    public var autoJumpToLocationServices: Bool

    @Parameter(title: "intent.param.show_refresh_guide", default: true)
    public var showRefreshGuide: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Locate \(\.$place) and refresh cache") {
            \.$autoJumpToLocationServices
            \.$showRefreshGuide
        }
    }

    public init() {}

    public init(place: FavoritePlaceEntity) {
        self.place = place
        self.autoJumpToLocationServices = true
        self.showRefreshGuide = true
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        let vm = RelocViewModel.shared
        guard vm.isMFiSignerReady else {
            throw RelocIntentError.mfiUnavailable
        }
        let auth = vm.locationAuthorizationStatus
        if auth == .denied || auth == .restricted {
            throw RelocIntentError.locationPermissionDenied
        }

        let loc = TargetLocation(latitude: place.latitude, longitude: place.longitude, altitude: place.altitude)
        await vm.startFixedLocationFromShortcut(
            wgsLocation: loc,
            name: place.name,
            subtitle: place.subtitle
        )
        await vm.waitForShortcutAuthReady(timeoutSeconds: 2.5)

        if let err = vm.snapshot.lastError, !vm.snapshot.isRunning {
            throw RelocIntentError.sessionFailed(err)
        }

        if showRefreshGuide || autoJumpToLocationServices {
            await waitForForegroundWindow()
        }

        if autoJumpToLocationServices {
            if #available(iOS 18.2, *) {
                if showRefreshGuide {
                    vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                return .result(
                    value: systemLocationServicesPrefsURL,
                    opensIntent: OpenURLIntent(systemLocationServicesPrefsURL)
                )
            }
            if showRefreshGuide {
                vm.launchOneTapLocationRefresh(skipAutoSettingsJump: false)
            } else {
                vm.openLocationServicesSettings()
            }
        } else if showRefreshGuide {
            vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        return .result(value: systemLocationServicesPrefsURL)
    }
}

// MARK: - 2. Start Saved Route Simulation

public struct StartSavedRouteIntent: AppIntent {
    public static var title: LocalizedStringResource = "intent.start_route.title"
    public static var description = IntentDescription("intent.start_route.desc")
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "intent.param.route", requestValueDialog: IntentDialog("intent.prompt.choose_route"))
    public var route: SavedRouteEntity

    @Parameter(title: "intent.param.auto_jump_settings", default: true)
    public var autoJumpToLocationServices: Bool

    @Parameter(title: "intent.param.show_refresh_guide", default: true)
    public var showRefreshGuide: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Start route \(\.$route)") {
            \.$autoJumpToLocationServices
            \.$showRefreshGuide
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        let vm = RelocViewModel.shared
        guard vm.isMFiSignerReady else {
            throw RelocIntentError.mfiUnavailable
        }
        let auth = vm.locationAuthorizationStatus
        if auth == .denied || auth == .restricted {
            throw RelocIntentError.locationPermissionDenied
        }

        let started = await vm.startSavedRouteFromShortcut(routeID: route.id, routeName: route.name)
        guard started else {
            throw RelocIntentError.routeNotFound
        }
        await vm.waitForShortcutAuthReady(timeoutSeconds: 2.5)

        if let err = vm.snapshot.lastError, !vm.snapshot.isRunning {
            throw RelocIntentError.sessionFailed(err)
        }

        if showRefreshGuide || autoJumpToLocationServices {
            await waitForForegroundWindow()
        }

        if autoJumpToLocationServices {
            if #available(iOS 18.2, *) {
                if showRefreshGuide {
                    vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                return .result(
                    value: systemLocationServicesPrefsURL,
                    opensIntent: OpenURLIntent(systemLocationServicesPrefsURL)
                )
            }
            if showRefreshGuide {
                vm.launchOneTapLocationRefresh(skipAutoSettingsJump: false)
            } else {
                vm.openLocationServicesSettings()
            }
        } else if showRefreshGuide {
            vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        return .result(value: systemLocationServicesPrefsURL)
    }
}

// MARK: - 3. Start Virtual Location at Custom Coordinate

public struct StartCoordinateIntent: AppIntent {
    public static var title: LocalizedStringResource = "intent.start_coord.title"
    public static var description = IntentDescription("intent.start_coord.desc")
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "intent.param.latitude")
    public var latitude: Double

    @Parameter(title: "intent.param.longitude")
    public var longitude: Double

    @Parameter(title: "intent.param.altitude")
    public var altitude: Double?

    @Parameter(title: "intent.param.place_name")
    public var placeName: String?

    @Parameter(title: "intent.param.is_gcj02", default: false)
    public var isGCJ02: Bool

    @Parameter(title: "intent.param.auto_jump_settings", default: true)
    public var autoJumpToLocationServices: Bool

    @Parameter(title: "intent.param.show_refresh_guide", default: true)
    public var showRefreshGuide: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Locate at (\(\.$latitude), \(\.$longitude))") {
            \.$altitude
            \.$placeName
            \.$isGCJ02
            \.$autoJumpToLocationServices
            \.$showRefreshGuide
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        let vm = RelocViewModel.shared
        guard vm.isMFiSignerReady else {
            throw RelocIntentError.mfiUnavailable
        }
        let auth = vm.locationAuthorizationStatus
        if auth == .denied || auth == .restricted {
            throw RelocIntentError.locationPermissionDenied
        }
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            throw RelocIntentError.invalidCoordinate
        }

        let wgs: CLLocationCoordinate2D = isGCJ02
            ? CoordinateTransform.gcj02ToWGS84(lat: latitude, lon: longitude)
            : CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let alt = altitude.flatMap { $0.isFinite ? min(50_000.0, max(-500.0, $0)) : nil } ?? vm.inspectedLocation.altitude
        let loc = TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: alt)

        await vm.startFixedLocationFromShortcut(
            wgsLocation: loc,
            name: placeName,
            subtitle: nil,
            resolveAltitude: altitude == nil
        )
        await vm.waitForShortcutAuthReady(timeoutSeconds: 2.5)

        if let err = vm.snapshot.lastError, !vm.snapshot.isRunning {
            throw RelocIntentError.sessionFailed(err)
        }

        if showRefreshGuide || autoJumpToLocationServices {
            await waitForForegroundWindow()
        }

        if autoJumpToLocationServices {
            if #available(iOS 18.2, *) {
                if showRefreshGuide {
                    vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                return .result(
                    value: systemLocationServicesPrefsURL,
                    opensIntent: OpenURLIntent(systemLocationServicesPrefsURL)
                )
            }
            if showRefreshGuide {
                vm.launchOneTapLocationRefresh(skipAutoSettingsJump: false)
            } else {
                vm.openLocationServicesSettings()
            }
        } else if showRefreshGuide {
            vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        return .result(value: systemLocationServicesPrefsURL)
    }
}

// MARK: - 4. Stop Virtual Location & Refresh System Location Services

public struct StopLocationIntent: AppIntent {
    public static var title: LocalizedStringResource = "intent.stop.title"
    public static var description = IntentDescription("intent.stop.desc")
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "intent.param.auto_jump_settings", default: true)
    public var autoJumpToLocationServices: Bool

    @Parameter(title: "intent.param.show_refresh_guide", default: true)
    public var showRefreshGuide: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Stop virtual location and refresh cache") {
            \.$autoJumpToLocationServices
            \.$showRefreshGuide
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        let vm = RelocViewModel.shared
        if vm.snapshot.isRunning {
            vm.stopAndRestore()
        }

        if showRefreshGuide || autoJumpToLocationServices {
            await waitForForegroundWindow()
        }

        if autoJumpToLocationServices {
            if #available(iOS 18.2, *) {
                if showRefreshGuide {
                    vm.launchOneTapRestoreRefresh(skipAutoSettingsJump: true)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                return .result(
                    value: systemLocationServicesPrefsURL,
                    opensIntent: OpenURLIntent(systemLocationServicesPrefsURL)
                )
            }
            if showRefreshGuide {
                vm.launchOneTapRestoreRefresh(skipAutoSettingsJump: false)
            } else {
                vm.openLocationServicesSettings()
            }
        } else if showRefreshGuide {
            vm.launchOneTapRestoreRefresh(skipAutoSettingsJump: true)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        return .result(value: systemLocationServicesPrefsURL)
    }
}

// MARK: - App Shortcuts Provider

public struct RelocAppShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor { .blue }

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFavoriteLocationIntent(),
            phrases: [
                "Start \(.applicationName)",
                "用 \(.applicationName) 开始定位",
                "开启 \(.applicationName) 虚拟定位",
                "用 \(.applicationName) 開始定位",
                "開啟 \(.applicationName) 虛擬定位",
                "\(.applicationName) で位置を開始",
                "\(.applicationName) で仮想位置を開始",
                "\(.applicationName) 위치 시작",
            ],
            shortTitle: "intent.start_favorite.short",
            systemImageName: "location.north.circle.fill"
        )
        AppShortcut(
            intent: StartSavedRouteIntent(),
            phrases: [
                "Start route in \(.applicationName)",
                "用 \(.applicationName) 开始轨迹",
                "用 \(.applicationName) 開始軌跡",
                "\(.applicationName) でルートを開始",
                "\(.applicationName) 경로 시작",
            ],
            shortTitle: "intent.start_route.short",
            systemImageName: "point.filled.topleft.down.curvedto.point.bottomright.up"
        )
        AppShortcut(
            intent: StopLocationIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "关闭 \(.applicationName) 虚拟定位",
                "停止 \(.applicationName) 定位",
                "關閉 \(.applicationName) 虛擬定位",
                "停止 \(.applicationName) 定位",
                "\(.applicationName) の位置を停止",
                "\(.applicationName) を停止",
                "\(.applicationName) 위치 중지",
            ],
            shortTitle: "intent.stop.short",
            systemImageName: "stop.circle.fill"
        )
    }
}
