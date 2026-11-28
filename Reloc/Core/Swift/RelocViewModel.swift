import Combine
import CoreLocation
import Foundation
import MapKit
import Network
import SwiftUI
import UIKit

public enum InjectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case waitingSubscription
    case injectingPendingLock
    case activeConfirmed
}

@MainActor
public final class RelocViewModel: ObservableObject {
    public static let shared = RelocViewModel()

    public let store = CredentialStore()
    public let coreLocation = LiveCoreLocationMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let geocoder = CLGeocoder()
    private var cancellables = Set<AnyCancellable>()

    @Published public var intervalSeconds: Double {
        didSet { store.intervalSeconds = intervalSeconds }
    }
    @Published public var durationSeconds: Double {
        didSet { store.durationSeconds = durationSeconds }
    }
    @Published public var gcj02CorrectionEnabled: Bool {
        didSet { store.gcj02CorrectionEnabled = gcj02CorrectionEnabled }
    }
    @Published public var microJitterEnabled: Bool {
        didSet {
            store.microJitterEnabled = microJitterEnabled
            session?.setMicroJitterEnabled(microJitterEnabled)
        }
    }
    @Published public var backgroundLocationIndicatorEnabled: Bool {
        didSet {
            store.backgroundLocationIndicatorEnabled = backgroundLocationIndicatorEnabled
            keepAlive.setBackgroundIndicatorEnabled(backgroundLocationIndicatorEnabled)
        }
    }
    @Published public var appearanceMode: AppAppearanceMode {
        didSet { store.appearanceMode = appearanceMode }
    }
    @Published public var appLanguage: AppLanguage {
        didSet {
            store.appLanguage = appLanguage
            reverseGeocode(wgsLocation: inspectedLocation)
        }
    }
    @Published public var mapStyle: MapDisplayStyle {
        didSet { store.mapStyle = mapStyle }
    }
    @Published public var mapSource: MapSource {
        didSet { store.mapSource = mapSource }
    }
    @Published public var refreshCountdownPreset: RefreshCountdownPreset {
        didSet { store.refreshCountdownPreset = refreshCountdownPreset }
    }

    // MARK: - Target & Selected Location (WGS-84)
    /// The location currently being sent to the iPhone (or ready to send).
    @Published public var targetLocation: TargetLocation {
        didSet {
            store.lastTargetLocation = targetLocation
            pushLocationToSession()
        }
    }
    /// Candidate pin dropped on the map while a session is already active (allows browsing before tapping Update).
    @Published public var pendingLocation: TargetLocation?
    @Published public var selectedPlaceName: String = L10n.tr("map.selected_place")
    @Published public var selectedPlaceAddress: String = ""

    // MARK: - Favorites, Recents (30), Saved Routes, & Recovery
    @Published public var favorites: [FavoriteLocation] = []
    @Published public var recents: [RecentLocation] = []
    @Published public var savedRoutes: [SavedRoute] = []
    @Published public var interruptedSession: InterruptedSessionRecord?

    // MARK: - Trajectory / Route Simulation State
    @Published public var controlMode: LocationControlMode = .fixed {
        didSet {
            if controlMode != .route {
                isFreehandDrawing = false
            }
        }
    }
    @Published public var routeCreationMode: RouteCreationMode = .road {
        didSet {
            if routeCreationMode == .road {
                isFreehandDrawing = false
            } else if routeCreationMode == .freehand && !isRouteSessionActive && plannedRoutePoints.count < 2 {
                isFreehandDrawing = true
            }
        }
    }
    @Published public var isFreehandDrawing = false
    @Published public var routeWaypoints: [RouteWaypoint] = []
    @Published public var plannedRoutePoints: [RoutePoint] = []
    @Published public var plannedRouteDistanceMeters: Double = 0
    @Published public var isPlanningRoute = false
    @Published public var routePlanningNotice: String?
    @Published public var importedRouteTitle: String?
    @Published public var pendingCameraFocus: CLLocationCoordinate2D?
    private var freehandBasePoints: [RoutePoint] = []
    private var previousFreehandBasePoints: [RoutePoint]?
    public var isCurrentRouteFreehand: Bool {
        routeCreationMode == .freehand || !freehandBasePoints.isEmpty
    }
    public var canUndoFreehandRoute: Bool {
        !freehandBasePoints.isEmpty || previousFreehandBasePoints != nil
    }
    @Published public var routePreset: RouteTransportPreset {
        didSet {
            store.routePreset = routePreset
            if oldValue != routePreset {
                if !suppressRouteReplan {
                    routeSpeedMps = routePreset.defaultSpeedMps
                }
                session?.setTrajectoryPreset(routePreset)
                if !suppressRouteReplan && !isRouteSessionActive && freehandBasePoints.isEmpty && routeWaypoints.count >= 2 && !oldValue.hasSameRoadTopology(as: routePreset) {
                    replanCurrentRoute()
                }
            }
        }
    }
    @Published public var routeSpeedMps: Double {
        didSet {
            store.routeSpeedMps = routeSpeedMps
            session?.setTrajectorySpeed(routeSpeedMps)
        }
    }
    @Published public var routeLoopMode: RouteLoopMode {
        didSet {
            store.routeLoopMode = routeLoopMode
            session?.setTrajectoryLoopMode(routeLoopMode)
            if !suppressRouteReplan && !isRouteSessionActive {
                if !freehandBasePoints.isEmpty {
                    rebuildFreehandRouteForLoopMode()
                } else if routeWaypoints.count >= 3 && (oldValue == .loop || routeLoopMode == .loop) {
                    replanCurrentRoute()
                }
            }
        }
    }
    @Published public var routeRealisticMotionEnabled: Bool {
        didSet {
            store.routeRealisticMotionEnabled = routeRealisticMotionEnabled
            session?.setTrajectoryRealisticMotion(routeRealisticMotionEnabled)
        }
    }
    @Published public var routeStopGoalKind: RouteStopGoalKind {
        didSet { store.routeStopGoalKind = routeStopGoalKind }
    }
    @Published public var routeTargetDistanceKm: Double {
        didSet { store.routeTargetDistanceKm = routeTargetDistanceKm }
    }
    @Published public var routeTargetLaps: Int {
        didSet { store.routeTargetLaps = routeTargetLaps }
    }
    @Published public var routeBriefStopsEnabled: Bool {
        didSet {
            store.routeBriefStopsEnabled = routeBriefStopsEnabled
            session?.setTrajectoryBriefStops(routeBriefStopsEnabled)
        }
    }
    @Published public var routeStartProgress: Double = 0.0
    @Published public var trajectoryProgress: TrajectoryProgress?
    @Published public var isRouteSessionActive = false

    // MARK: - Joystick (Free-Roam) Simulation State
    @Published public var joystickSpeedMps: Double {
        didSet {
            store.joystickSpeedMps = joystickSpeedMps
            session?.setJoystickSpeed(joystickSpeedMps)
        }
    }
    @Published public var joystickCruiseLocked = false
    @Published public var isJoystickSessionActive = false
    @Published public var joystickProgress: JoystickProgress?

    // MARK: - Altitude Resolution
    @Published public var isResolvingAltitude = false

    // MARK: - Session & Diagnostics
    @Published public var snapshot = SessionSnapshot()
    @Published public var injectionPhase: InjectionPhase = .idle
    @Published public var isAccessoryLocationConfirmed = false
    @Published public var needsLocationServiceRefresh = false
    @Published public var isLocationRefreshGuideActive = false
    @Published public var isRestoringRealLocation = false
    @Published public var needsRestoreLocationRefresh = false
    @Published public var realLocationRestoredNotice = false
    @Published public private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var isLocationReducedAccuracy = false
    @Published public var events: [ProtocolEvent] = []
    @Published public var alertMessage: String?

    private var mfiSigner: RLMFiSigner?
    private var session: AccessoryLocationSession?
    private var lastKnownRealLocation: TargetLocation?
    private var lastPersistedRealLocation: TargetLocation?
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(label: "com.reloc.netpath", qos: .utility)
    private var lastNetworkSatisfied: Bool?
    private var isAppInForeground = true
    private var pendingBackgroundSnapshot: SessionSnapshot?
    private var pendingBackgroundTrajectoryProgress: TrajectoryProgress?
    private var pendingBackgroundJoystickProgress: JoystickProgress?
    private var routePlanningTask: Task<Void, Never>?
    private var routePlanningGeneration: Int = 0
    private var suppressRouteReplan = false
    private var subscriptionPulseTask: Task<Void, Never>?
    private var lockWatchdogTask: Task<Void, Never>?
    private var postRefreshRecoveryTask: Task<Void, Never>?
    private var unexpectedStopRecoveryTask: Task<Void, Never>?
    private var refreshCountdownTask: Task<Void, Never>?
    private var locationStopDebounceTask: Task<Void, Never>?
    private var locationRefreshSawDisabled = false
    private var locationRefreshRetryCount = 0
    private var consecutiveLockLossCount = 0
    private var lastAccessoryVerticalAccuracy: Double?
    private var consecutiveVertAccIncreases = 0
    private var lastAccessoryReportedCoordinate: CLLocationCoordinate2D?
    private var lastAutoReconnectAt: TimeInterval = 0
    private let autoReconnectCooldownSeconds: TimeInterval = 90.0
    private var loggedReducedAccuracyForSession = false
    private var restoreTask: Task<Void, Never>?
    private var isRestoreRefreshGuideActive = false
    private var lastRestoreAuthStatus: CLAuthorizationStatus = .notDetermined
    private var geocodeTask: Task<Void, Never>?
    private var geocodeGeneration: Int = 0
    private var elevationTask: Task<Void, Never>?
    private var elevationGeneration: Int = 0

    public var isAlwaysLocationAuthorized: Bool {
        locationAuthorizationStatus == .authorizedAlways
    }

    /// Distance in meters between the device's last known real location and the inspected/active target.
    public var distanceFromRealLocationMeters: Double? {
        let real: TargetLocation?
        if let cached = lastKnownRealLocation {
            real = cached
        } else if let latest = coreLocation.latest, latest.isProducedByAccessory == false {
            real = TargetLocation(latitude: latest.latitude, longitude: latest.longitude, altitude: latest.altitude)
        } else {
            real = nil
        }
        guard let real else { return nil }
        let target: TargetLocation
        if snapshot.isRunning {
            target = session?.currentComparisonLocation() ?? targetLocation
        } else if controlMode == .route, let startPt = RouteGeometry.samplePoint(along: plannedRoutePoints, atProgress: routeStartProgress) {
            target = TargetLocation(latitude: startPt.latitude, longitude: startPt.longitude, altitude: startPt.altitude)
        } else {
            target = inspectedLocation
        }
        return RouteGeometry.distanceMeters(
            lat1: real.latitude,
            lon1: real.longitude,
            lat2: target.latitude,
            lon2: target.longitude
        )
    }

    /// True when the inspected pre-start target is > 15 km from the device's known real location.
    public var isInspectedLocationDistant: Bool {
        (distanceFromRealLocationMeters ?? 0) > 15_000.0
    }

    /// True when the active target is > 15 km from the device's last known real location,
    /// where iOS `CLNmeaScreener` will reject accessory NMEA whenever Wi-Fi/Cell scanning runs.
    public var isDistantFromRealLocation: Bool {
        guard let real = lastKnownRealLocation else { return false }
        let expected = session?.currentComparisonLocation() ?? targetLocation
        let dist = RouteGeometry.distanceMeters(
            lat1: real.latitude,
            lon1: real.longitude,
            lat2: expected.latitude,
            lon2: expected.longitude
        )
        return dist > 15_000.0
    }

    /// Effective PiP refresh countdown seconds (honoring Auto distant escalation or user override).
    public var effectiveRefreshCountdownSeconds: Int {
        refreshCountdownPreset.effectiveSeconds(isDistant: isDistantFromRealLocation || isInspectedLocationDistant)
    }

    public var effectiveRouteTargetDistanceMeters: Double? {
        routeStopGoalKind == .distance ? max(200.0, routeTargetDistanceKm * 1000.0) : nil
    }

    public var effectiveRouteTargetLaps: Int? {
        routeStopGoalKind == .laps && routeLoopMode != .once ? max(1, routeTargetLaps) : nil
    }

    public init() {
        self.intervalSeconds = store.intervalSeconds
        self.durationSeconds = store.durationSeconds
        self.gcj02CorrectionEnabled = store.gcj02CorrectionEnabled
        self.microJitterEnabled = store.microJitterEnabled
        self.backgroundLocationIndicatorEnabled = store.backgroundLocationIndicatorEnabled
        self.appearanceMode = store.appearanceMode
        self.appLanguage = store.appLanguage
        self.mapStyle = store.mapStyle
        self.mapSource = store.mapSource
        self.refreshCountdownPreset = store.refreshCountdownPreset
        self.targetLocation = store.lastTargetLocation
        let initialPreset = store.routePreset
        self.routePreset = initialPreset
        self.routeSpeedMps = store.routeSpeedMps
        self.routeLoopMode = store.routeLoopMode
        self.routeRealisticMotionEnabled = store.routeRealisticMotionEnabled
        self.routeStopGoalKind = store.routeStopGoalKind
        self.routeTargetDistanceKm = store.routeTargetDistanceKm
        self.routeTargetLaps = store.routeTargetLaps
        self.routeBriefStopsEnabled = store.routeBriefStopsEnabled
        self.joystickSpeedMps = store.joystickSpeedMps
        self.favorites = store.loadFavorites()
        self.recents = store.loadRecents()
        self.savedRoutes = store.loadSavedRoutes()
        self.interruptedSession = store.loadInterruptedSession()
        self.locationAuthorizationStatus = coreLocation.authorizationStatus
        self.isLocationReducedAccuracy = coreLocation.isReducedAccuracy
        self.isAppInForeground = UIApplication.shared.applicationState != .background

        self.mfiSigner = store.loadBundledMFiSigner()
        self.lastKnownRealLocation = store.loadCachedRealLocation()
        self.lastPersistedRealLocation = self.lastKnownRealLocation
        self.keepAlive.setBackgroundIndicatorEnabled(self.backgroundLocationIndicatorEnabled)

        LocationRefreshPresenter.shared.onGuideClosed = { [weak self] in
            self?.handleRefreshGuideClosed()
        }

        // Detect offline / Airplane Mode transitions so unconfirmed distant sessions immediately
        // boost NMEA acquisition and nudge CoreLocation without requiring manual retry.
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasSatisfied = self.lastNetworkSatisfied
                self.lastNetworkSatisfied = satisfied
                if wasSatisfied == true && !satisfied,
                   self.snapshot.isRunning,
                   !self.isAccessoryLocationConfirmed,
                   !self.isLocationRefreshGuideActive {
                    self.events.append(ProtocolEvent(
                        name: "network_offline_lock_boost",
                        detail: "{\"event\":\"network_offline_lock_boost\"}"
                    ))
                    self.session?.triggerFastBurst(seconds: 15.0)
                    if self.snapshot.activeSentences.isEmpty {
                        self.keepAlive.refreshAfterLocationToggle()
                    } else {
                        self.keepAlive.nudgeLocationSubscription()
                    }
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)

        self.keepAlive.onDiagnostic = { [weak self] event, details in
            guard let self else { return }
            var payload = details
            payload["event"] = event
            let detailText: String
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                detailText = str
            } else {
                detailText = "{\"event\":\"\(event)\"}"
            }
            self.events.append(ProtocolEvent(name: event, detail: detailText))
            if self.events.count > 500 {
                self.events.removeFirst(self.events.count - 500)
            }
        }

        self.keepAlive.onLocationUpdate = { [weak self] loc in
            guard let self else { return }
            self.coreLocation.ingestExternalLocation(loc, publishToUI: self.isAppInForeground)
        }

        self.keepAlive.onAuthorizationChange = { [weak self] status, accuracy in
            guard let self else { return }
            self.coreLocation.syncAuthorization(status: status, accuracy: accuracy)
        }

        self.keepAlive.onForegroundResume = { [weak self] in
            self?.handleAppEnteredForeground()
        }

        self.coreLocation.onTelemetryUpdate = { [weak self] telemetry in
            self?.evaluateCoreLocationConfirmation(telemetry)
        }

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isAppInForeground = false
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleAppEnteredForeground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleAppEnteredForeground()
            }
            .store(in: &cancellables)

        self.coreLocation.$authorizationStatus
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if self.locationAuthorizationStatus != status {
                    self.locationAuthorizationStatus = status
                }
                self.isLocationReducedAccuracy = self.coreLocation.isReducedAccuracy
                self.handleCoreLocationAuthChangeForRestore(status)
            }
            .store(in: &cancellables)

        self.coreLocation.$accuracyAuthorization
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isLocationReducedAccuracy = self.coreLocation.isReducedAccuracy
            }
            .store(in: &cancellables)

        reverseGeocode(wgsLocation: targetLocation)
    }

    private func handleAppEnteredForeground() {
        isAppInForeground = true
        if let pending = pendingBackgroundSnapshot {
            pendingBackgroundSnapshot = nil
            snapshot = pending
            updateInjectionPhase()
        }
        if let pendingProg = pendingBackgroundTrajectoryProgress {
            pendingBackgroundTrajectoryProgress = nil
            trajectoryProgress = pendingProg
        }
        if let pendingJoy = pendingBackgroundJoystickProgress {
            pendingBackgroundJoystickProgress = nil
            joystickProgress = pendingJoy
        }
        coreLocation.flushLatestToUI()
        if snapshot.isRunning {
            session?.wakeForImmediateReconnect()
            if isLocationRefreshGuideActive && !LocationRefreshPresenter.shared.isActive {
                handleRefreshGuideClosed()
            }
        }
    }

    // MARK: - Coordinate Mapping Helpers

    /// True only when displaying Apple's native MapKit with Mainland China GCJ-02 correction enabled.
    /// Pure WGS-84 tile sources (CARTO / OSM / Esri) never apply GCJ-02 display shift.
    public var usesGCJ02MapCoordinates: Bool {
        !mapSource.isPureWGS84 && gcj02CorrectionEnabled
    }

    public func toMapCoordinate(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if usesGCJ02MapCoordinates {
            return CoordinateTransform.wgs84ToGCJ02(lat: wgs.latitude, lon: wgs.longitude)
        }
        return wgs
    }

    public func fromMapCoordinate(_ mapCoord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if usesGCJ02MapCoordinates {
            return CoordinateTransform.gcj02ToWGS84(lat: mapCoord.latitude, lon: mapCoord.longitude)
        }
        return mapCoord
    }

    /// Converts a search result coordinate into canonical WGS-84.
    /// Apple's `MKLocalSearch` returns GCJ-02 for Mainland China POIs regardless of custom tile overlays,
    /// while Hong Kong, Macau, Taiwan, Japan, Korea, all overseas POIs, and OSM Nominatim results are pure WGS-84.
    public func selectSearchResultCoordinate(
        _ searchCoord: CLLocationCoordinate2D,
        isoCountryCode: String? = nil,
        isPureWGS84: Bool = false,
        name: String? = nil,
        address: String? = nil
    ) {
        let wgs: CLLocationCoordinate2D
        if !isPureWGS84 && gcj02CorrectionEnabled && CoordinateTransform.shouldApplyGCJ02(
            lat: searchCoord.latitude,
            lon: searchCoord.longitude,
            isoCountryCode: isoCountryCode
        ) {
            wgs = CoordinateTransform.gcj02ToWGS84(lat: searchCoord.latitude, lon: searchCoord.longitude)
        } else {
            wgs = searchCoord
        }
        selectWGSLocation(
            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: name,
            address: address,
            resolveAltitude: true
        )
    }

    public var activeMapCoordinate: CLLocationCoordinate2D {
        if isRouteSessionActive, let loc = trajectoryProgress?.currentLocation {
            return toMapCoordinate(CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude))
        }
        if isJoystickSessionActive, let loc = joystickProgress?.currentLocation {
            return toMapCoordinate(CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude))
        }
        if controlMode == .route {
            if let preview = routeStartPreviewCoordinate {
                return preview
            }
            if let first = routeWaypoints.first {
                return toMapCoordinate(first.coordinate)
            }
        }
        return toMapCoordinate(CLLocationCoordinate2D(latitude: targetLocation.latitude, longitude: targetLocation.longitude))
    }

    /// Preview pin coordinate along the planned polyline when starting from mid-route (`routeStartProgress > 0`).
    public var routeStartPreviewCoordinate: CLLocationCoordinate2D? {
        guard controlMode == .route,
              !isRouteSessionActive,
              plannedRoutePoints.count >= 2,
              routeStartProgress > 0.005,
              let pt = RouteGeometry.samplePoint(along: plannedRoutePoints, atProgress: routeStartProgress) else {
            return nil
        }
        return toMapCoordinate(pt.coordinate)
    }

    public var routeMapPolylineCoordinates: [CLLocationCoordinate2D] {
        guard controlMode == .route || isRouteSessionActive else { return [] }
        return plannedRoutePoints.map { toMapCoordinate($0.coordinate) }
    }

    public var routeMapWaypointCoordinates: [CLLocationCoordinate2D] {
        guard controlMode == .route || isRouteSessionActive else { return [] }
        return routeWaypoints.map { toMapCoordinate($0.coordinate) }
    }

    public var canDragRouteWaypoints: Bool {
        controlMode == .route && !isRouteSessionActive && !isFreehandDrawing && freehandBasePoints.isEmpty && !routeWaypoints.isEmpty
    }

    public var canStartRouteSession: Bool {
        mfiSigner != nil
            && !snapshot.isRunning
            && !isPlanningRoute
            && plannedRoutePoints.count >= 2
            && plannedRouteDistanceMeters >= 1.0
    }

    public var currentLiveCoordinateSummary: TargetLocation {
        if isRouteSessionActive, let loc = trajectoryProgress?.currentLocation {
            return loc
        }
        if isJoystickSessionActive, let loc = joystickProgress?.currentLocation {
            return loc
        }
        return targetLocation
    }

    // MARK: - Trajectory Route Planning & Saved Routes

    public func addRouteWaypoint(fromMapCoordinate mapCoord: CLLocationCoordinate2D, name: String? = nil) {
        guard !isRouteSessionActive else { return }
        let wgs = fromMapCoordinate(mapCoord)
        let defaultName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (defaultName?.isEmpty == false)
            ? defaultName!
            : String(format: "%.5f, %.5f", wgs.latitude, wgs.longitude)
        addRouteWaypointWGS(
            RoutePoint(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: resolvedName
        )
    }

    public func addRouteWaypoint(
        fromSearchCoordinate searchCoord: CLLocationCoordinate2D,
        isoCountryCode: String? = nil,
        isPureWGS84: Bool = false,
        name: String? = nil
    ) {
        guard !isRouteSessionActive else { return }
        let wgs: CLLocationCoordinate2D
        if !isPureWGS84 && gcj02CorrectionEnabled && CoordinateTransform.shouldApplyGCJ02(
            lat: searchCoord.latitude,
            lon: searchCoord.longitude,
            isoCountryCode: isoCountryCode
        ) {
            wgs = CoordinateTransform.gcj02ToWGS84(lat: searchCoord.latitude, lon: searchCoord.longitude)
        } else {
            wgs = searchCoord
        }
        let defaultName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (defaultName?.isEmpty == false)
            ? defaultName!
            : String(format: "%.5f, %.5f", wgs.latitude, wgs.longitude)
        addRouteWaypointWGS(
            RoutePoint(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: resolvedName
        )
    }

    /// Moves an existing road-route waypoint after dragging its pin on the map and replans the route.
    public func moveRouteWaypoint(at index: Int, toMapCoordinate mapCoord: CLLocationCoordinate2D) {
        guard !isRouteSessionActive,
              freehandBasePoints.isEmpty,
              routeWaypoints.indices.contains(index) else { return }
        let wgs = fromMapCoordinate(mapCoord)
        var updated = routeWaypoints[index]
        updated.latitude = wgs.latitude
        updated.longitude = wgs.longitude
        updated.name = String(format: "%.5f, %.5f", wgs.latitude, wgs.longitude)
        routeWaypoints[index] = updated
        routeStartProgress = 0.0
        if routeWaypoints.count >= 2 {
            replanCurrentRoute()
        } else {
            plannedRoutePoints = [updated.routePoint]
            plannedRouteDistanceMeters = 0
        }
    }

    public func addRouteWaypointWGS(_ point: RoutePoint, name: String) {
        guard !isRouteSessionActive else { return }
        if !freehandBasePoints.isEmpty {
            freehandBasePoints = []
            previousFreehandBasePoints = nil
            importedRouteTitle = nil
            routeWaypoints = []
            plannedRoutePoints = []
            plannedRouteDistanceMeters = 0
        }
        routeCreationMode = .road
        let wp = RouteWaypoint(
            name: name,
            latitude: point.latitude,
            longitude: point.longitude,
            altitude: point.altitude
        )
        routeWaypoints.append(wp)
        if routeWaypoints.count >= 2 {
            replanCurrentRoute()
        } else {
            plannedRoutePoints = [point]
            plannedRouteDistanceMeters = 0
            routePlanningNotice = nil
        }
    }

    public func beginFreehandDrawing() {
        guard !isRouteSessionActive else { return }
        controlMode = .route
        routeCreationMode = .freehand
        isFreehandDrawing = true
    }

    public func cancelFreehandDrawing() {
        isFreehandDrawing = false
    }

    /// Commits a user-drawn map-coordinate stroke as a smooth freehand trajectory.
    public func commitFreehandStroke(mapCoordinates: [CLLocationCoordinate2D]) {
        guard !isRouteSessionActive else { return }
        let wgsCoords = mapCoordinates.map { fromMapCoordinate($0) }
        guard let result = FreehandRouteProcessor.processStroke(
            rawCoordinates: wgsCoords,
            defaultAltitude: inspectedLocation.altitude,
            preferredLoopMode: routeLoopMode
        ) else {
            return
        }

        routePlanningTask?.cancel()
        routePlanningGeneration += 1
        let gen = routePlanningGeneration

        if !freehandBasePoints.isEmpty {
            previousFreehandBasePoints = freehandBasePoints
        }
        freehandBasePoints = result.basePoints
        importedRouteTitle = nil
        isFreehandDrawing = false
        routeCreationMode = .freehand
        routePlanningNotice = nil
        routeStartProgress = 0.0

        if result.isClosedLoop && routeLoopMode != .loop {
            suppressRouteReplan = true
            routeLoopMode = .loop
            suppressRouteReplan = false
        }

        applyFreehandPoints(result.points, closed: result.isClosedLoop)

        // Enrich freehand vertices with smooth real terrain elevation in the background.
        let snapshotBase = freehandBasePoints
        routePlanningTask = Task { @MainActor [weak self] in
            let enrichedBase = await RoadRoutePlanner.enrichElevationProfile(for: snapshotBase)
            guard !Task.isCancelled,
                  let self,
                  !self.isRouteSessionActive,
                  self.routePlanningGeneration == gen,
                  !self.freehandBasePoints.isEmpty else {
                return
            }
            self.freehandBasePoints = enrichedBase
            let closed = self.routeLoopMode == .loop
            let rebuilt = FreehandRouteProcessor.buildPolyline(fromBase: enrichedBase, closed: closed)
            self.applyFreehandPoints(rebuilt, closed: closed)
        }
    }

    private func rebuildFreehandRouteForLoopMode() {
        guard !freehandBasePoints.isEmpty else { return }
        let closed = routeLoopMode == .loop
        let rebuilt = FreehandRouteProcessor.buildPolyline(fromBase: freehandBasePoints, closed: closed)
        applyFreehandPoints(rebuilt, closed: closed)
    }

    private func applyFreehandPoints(_ points: [RoutePoint], closed: Bool) {
        plannedRoutePoints = points
        plannedRouteDistanceMeters = RouteGeometry.totalDistance(of: points)
        guard let first = points.first, let last = points.last else {
            routeWaypoints = []
            return
        }
        let startWP = RouteWaypoint(
            name: L10n.tr("route.pin.start"),
            latitude: first.latitude,
            longitude: first.longitude,
            altitude: first.altitude
        )
        if closed || RouteGeometry.distanceMeters(from: first, to: last) <= 20.0 {
            routeWaypoints = [startWP]
        } else {
            let endWP = RouteWaypoint(
                name: L10n.tr("route.pin.end"),
                latitude: last.latitude,
                longitude: last.longitude,
                altitude: last.altitude
            )
            routeWaypoints = [startWP, endWP]
        }
    }

    public func undoLastRouteWaypoint() {
        guard !isRouteSessionActive else { return }
        if !freehandBasePoints.isEmpty {
            routePlanningTask?.cancel()
            routePlanningTask = nil
            isPlanningRoute = false
            if let prev = previousFreehandBasePoints {
                freehandBasePoints = prev
                previousFreehandBasePoints = nil
                rebuildFreehandRouteForLoopMode()
            } else {
                clearRoute()
            }
            return
        }
        guard !routeWaypoints.isEmpty else { return }
        routeWaypoints.removeLast()
        if routeWaypoints.count >= 2 {
            replanCurrentRoute()
        } else {
            routePlanningTask?.cancel()
            routePlanningTask = nil
            isPlanningRoute = false
            plannedRoutePoints = routeWaypoints.map(\.routePoint)
            plannedRouteDistanceMeters = 0
            routePlanningNotice = nil
        }
    }

    public func reverseRouteWaypoints() {
        guard !isRouteSessionActive else { return }
        routeStartProgress = 0.0
        if !freehandBasePoints.isEmpty {
            freehandBasePoints.reverse()
            rebuildFreehandRouteForLoopMode()
            return
        }
        guard routeWaypoints.count >= 2 else { return }
        routeWaypoints.reverse()
        replanCurrentRoute()
    }

    public func clearRoute() {
        guard !isRouteSessionActive else { return }
        routePlanningTask?.cancel()
        routePlanningTask = nil
        isPlanningRoute = false
        freehandBasePoints = []
        previousFreehandBasePoints = nil
        importedRouteTitle = nil
        routeWaypoints = []
        plannedRoutePoints = []
        plannedRouteDistanceMeters = 0
        routeStartProgress = 0.0
        routePlanningNotice = nil
        if routeCreationMode == .freehand {
            isFreehandDrawing = true
        }
    }

    public func replanCurrentRoute() {
        routePlanningTask?.cancel()
        routePlanningGeneration += 1
        let gen = routePlanningGeneration
        let waypoints = routeWaypoints
        let preset = routePreset
        let loopMode = routeLoopMode
        let gcj02 = gcj02CorrectionEnabled

        guard waypoints.count >= 2 else {
            isPlanningRoute = false
            plannedRoutePoints = waypoints.map(\.routePoint)
            plannedRouteDistanceMeters = 0
            routePlanningNotice = nil
            return
        }

        isPlanningRoute = true
        routePlanningNotice = nil
        routePlanningTask = Task { @MainActor [weak self] in
            let result = await RoadRoutePlanner.planRoute(
                waypoints: waypoints,
                preset: preset,
                loopMode: loopMode,
                gcj02CorrectionEnabled: gcj02
            )
            guard !Task.isCancelled, let self, self.routePlanningGeneration == gen else { return }
            self.isPlanningRoute = false
            self.plannedRoutePoints = result.points
            self.plannedRouteDistanceMeters = result.totalDistanceMeters
            if result.usedStraightFallback && !result.usedRoadRouting {
                self.routePlanningNotice = L10n.tr("route.notice.straight_fallback")
            } else if result.usedStraightFallback {
                self.routePlanningNotice = L10n.tr("route.notice.partial_fallback")
            } else {
                self.routePlanningNotice = nil
            }
        }
    }

    public func saveCurrentRoute(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, plannedRoutePoints.count >= 2 else { return }
        let route = SavedRoute(
            name: trimmed,
            waypoints: routeWaypoints,
            points: plannedRoutePoints,
            preset: routePreset,
            speedMetersPerSecond: routeSpeedMps,
            loopMode: routeLoopMode,
            totalDistanceMeters: plannedRouteDistanceMeters,
            isFreehand: !freehandBasePoints.isEmpty,
            targetDistanceMeters: effectiveRouteTargetDistanceMeters,
            targetLaps: effectiveRouteTargetLaps
        )
        savedRoutes.insert(route, at: 0)
        store.saveSavedRoutes(savedRoutes)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func renameSavedRoute(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = savedRoutes.firstIndex(where: { $0.id == id }) else { return }
        savedRoutes[idx].name = trimmed
        store.saveSavedRoutes(savedRoutes)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func deleteSavedRoute(id: UUID) {
        savedRoutes.removeAll { $0.id == id }
        store.saveSavedRoutes(savedRoutes)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func loadSavedRoute(_ route: SavedRoute) {
        guard !snapshot.isRunning else { return }
        routePlanningTask?.cancel()
        routePlanningTask = nil
        isPlanningRoute = false
        suppressRouteReplan = true
        defer { suppressRouteReplan = false }
        controlMode = .route
        isFreehandDrawing = false
        routeCreationMode = route.isFreehand ? .freehand : .road
        freehandBasePoints = route.isFreehand ? route.points : []
        previousFreehandBasePoints = nil
        importedRouteTitle = route.isFreehand ? route.name : nil
        routeWaypoints = route.waypoints
        plannedRoutePoints = route.points
        plannedRouteDistanceMeters = route.totalDistanceMeters
        routePreset = route.preset
        routeSpeedMps = route.speedMetersPerSecond
        routeLoopMode = route.loopMode
        routeStartProgress = 0.0
        if let distGoal = route.targetDistanceMeters, distGoal >= 200.0 {
            routeStopGoalKind = .distance
            routeTargetDistanceKm = (distGoal / 100.0).rounded() / 10.0
        } else if let lapGoal = route.targetLaps, lapGoal >= 1 {
            routeStopGoalKind = .laps
            routeTargetLaps = lapGoal
        } else {
            routeStopGoalKind = .none
        }
        routePlanningNotice = nil
    }

    // MARK: - GPX Import & Export

    /// Imports a `.gpx` file (track, route, or waypoint) into Reloc without overwriting coordinates via road routing.
    @discardableResult
    public func importGPXFile(from url: URL) -> Bool {
        guard !isRouteSessionActive else {
            alertMessage = L10n.tr("gpx.error.stop_session_first")
            return false
        }
        do {
            let result = try GPXCodec.parse(fileURL: url, defaultAltitude: inspectedLocation.altitude)
            if result.isSinglePoint, let pt = result.points.first {
                controlMode = .fixed
                isFreehandDrawing = false
                selectWGSLocation(
                    TargetLocation(latitude: pt.latitude, longitude: pt.longitude, altitude: pt.altitude),
                    name: result.name,
                    resolveAltitude: !result.hasElevation
                )
                pendingCameraFocus = pendingMapCoordinate ?? activeMapCoordinate
                return true
            }

            routePlanningTask?.cancel()
            routePlanningGeneration += 1
            let gen = routePlanningGeneration

            if !freehandBasePoints.isEmpty {
                previousFreehandBasePoints = freehandBasePoints
            }
            controlMode = .route
            isFreehandDrawing = false
            routeCreationMode = .freehand
            freehandBasePoints = result.points
            importedRouteTitle = result.name
            routePlanningNotice = nil
            routeStartProgress = 0.0

            let shouldLoop = result.isClosedLoop
            suppressRouteReplan = true
            routeLoopMode = shouldLoop ? .loop : (routeLoopMode == .loop ? .once : routeLoopMode)
            suppressRouteReplan = false

            let activeClosed = routeLoopMode == .loop
            let finalPoints = FreehandRouteProcessor.buildPolyline(fromBase: result.points, closed: activeClosed)
            applyFreehandPoints(finalPoints, closed: activeClosed)
            if let first = finalPoints.first {
                pendingCameraFocus = toMapCoordinate(first.coordinate)
            }

            if !result.hasElevation {
                let snapshotBase = freehandBasePoints
                routePlanningTask = Task { @MainActor [weak self] in
                    let enrichedBase = await RoadRoutePlanner.enrichElevationProfile(for: snapshotBase)
                    guard !Task.isCancelled, let self, self.routePlanningGeneration == gen, !self.freehandBasePoints.isEmpty else {
                        return
                    }
                    self.freehandBasePoints = enrichedBase
                    let closed = self.routeLoopMode == .loop
                    let rebuilt = FreehandRouteProcessor.buildPolyline(fromBase: enrichedBase, closed: closed)
                    self.applyFreehandPoints(rebuilt, closed: closed)
                }
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// Exports the currently planned route (road, freehand, or imported GPX) to a temporary `.gpx` file URL.
    public func exportCurrentRouteToGPX(suggestedName: String) -> URL? {
        guard plannedRoutePoints.count >= 2 else { return nil }
        let data = GPXCodec.exportRoute(
            name: suggestedName,
            points: plannedRoutePoints,
            waypoints: routeWaypoints,
            speedMetersPerSecond: routeSpeedMps
        )
        do {
            return try GPXCodec.writeTemporaryFile(name: suggestedName, data: data)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Exports a saved route to a temporary `.gpx` file URL.
    public func exportSavedRouteToGPX(_ route: SavedRoute) -> URL? {
        guard route.points.count >= 2 else { return nil }
        let data = GPXCodec.exportRoute(
            name: route.name,
            points: route.points,
            waypoints: route.waypoints,
            speedMetersPerSecond: route.speedMetersPerSecond,
            startDate: route.createdAt
        )
        do {
            return try GPXCodec.writeTemporaryFile(name: route.name, data: data)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Exports the currently inspected fixed pin as a GPX 1.1 waypoint file.
    public func exportCurrentPinToGPX() -> URL? {
        let loc = inspectedLocation
        let name = selectedPlaceName.isEmpty ? "Reloc_Pin" : selectedPlaceName
        let data = GPXCodec.exportWaypoint(name: name, location: loc)
        do {
            return try GPXCodec.writeTemporaryFile(name: name, data: data)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Exports a specific favorite place as a GPX 1.1 waypoint file.
    public func exportFavoriteToGPX(_ favorite: FavoriteLocation) -> URL? {
        let loc = TargetLocation(latitude: favorite.latitude, longitude: favorite.longitude, altitude: favorite.altitude)
        let data = GPXCodec.exportWaypoint(name: favorite.name, location: loc)
        do {
            return try GPXCodec.writeTemporaryFile(name: favorite.name, data: data)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Favorites & Routes Backup (JSON Import / Export)

    /// Exports all saved places and saved routes as a versioned Reloc JSON backup file.
    public func exportBackupArchive() -> URL? {
        guard !favorites.isEmpty || !savedRoutes.isEmpty else {
            alertMessage = L10n.tr("backup.error.nothing_to_export")
            return nil
        }
        do {
            let data = try RelocBackupCodec.encode(favorites: favorites, savedRoutes: savedRoutes)
            return try RelocBackupCodec.writeTemporaryBackupFile(data: data)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Imports a Reloc JSON backup archive, merging favorites and routes non-destructively without duplicates.
    @discardableResult
    public func importBackupArchive(from url: URL) -> RelocBackupImportSummary? {
        do {
            let archive = try RelocBackupCodec.decode(fileURL: url)
            var addedFavorites = 0
            var updatedFavorites = 0
            var mergedFavorites = favorites

            for incoming in archive.favorites {
                if let idx = mergedFavorites.firstIndex(where: { existing in
                    existing.id == incoming.id || (
                        existing.name == incoming.name
                        && RouteGeometry.distanceMeters(
                            lat1: existing.latitude, lon1: existing.longitude,
                            lat2: incoming.latitude, lon2: incoming.longitude
                        ) < 10.0
                    )
                }) {
                    if mergedFavorites[idx] != incoming {
                        mergedFavorites[idx] = incoming
                        updatedFavorites += 1
                    }
                } else {
                    mergedFavorites.append(incoming)
                    addedFavorites += 1
                }
            }

            var addedRoutes = 0
            var updatedRoutes = 0
            var mergedRoutes = savedRoutes

            for incoming in archive.savedRoutes {
                if let idx = mergedRoutes.firstIndex(where: { existing in
                    if existing.id == incoming.id { return true }
                    guard existing.name == incoming.name,
                          let eFirst = existing.points.first, let eLast = existing.points.last,
                          let iFirst = incoming.points.first, let iLast = incoming.points.last else {
                        return false
                    }
                    return abs(existing.totalDistanceMeters - incoming.totalDistanceMeters) < 5.0
                        && RouteGeometry.distanceMeters(from: eFirst, to: iFirst) < 10.0
                        && RouteGeometry.distanceMeters(from: eLast, to: iLast) < 10.0
                }) {
                    if mergedRoutes[idx] != incoming {
                        mergedRoutes[idx] = incoming
                        updatedRoutes += 1
                    }
                } else {
                    mergedRoutes.append(incoming)
                    addedRoutes += 1
                }
            }

            favorites = mergedFavorites
            savedRoutes = mergedRoutes
            store.saveFavorites(favorites)
            store.saveSavedRoutes(savedRoutes)
            RelocAppShortcuts.updateAppShortcutParameters()

            let summary = RelocBackupImportSummary(
                addedFavorites: addedFavorites,
                updatedFavorites: updatedFavorites,
                addedRoutes: addedRoutes,
                updatedRoutes: updatedRoutes
            )
            let updatedTotal = updatedFavorites + updatedRoutes
            if updatedTotal > 0 {
                alertMessage = L10n.format("backup.import.success_with_updates", addedFavorites, addedRoutes, updatedTotal)
            } else {
                alertMessage = L10n.format("backup.import.success", addedFavorites, addedRoutes)
            }
            return summary
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Auto-dispatches an imported file URL to JSON backup restore or GPX import based on file extension / content.
    @discardableResult
    public func importDataFile(from url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            return importBackupArchive(from: url) != nil
        }
        return importGPXFile(from: url)
    }

    public func toggleTrajectoryPause() {
        guard isRouteSessionActive, let current = trajectoryProgress else { return }
        let nextPaused = !current.isPaused
        session?.setTrajectoryPaused(nextPaused)
        var updated = current
        updated.isPaused = nextPaused
        if nextPaused {
            updated.currentSpeedMps = 0
        }
        trajectoryProgress = updated
    }

    public var pendingMapCoordinate: CLLocationCoordinate2D? {
        guard let pending = pendingLocation else { return nil }
        return toMapCoordinate(CLLocationCoordinate2D(latitude: pending.latitude, longitude: pending.longitude))
    }

    /// Coordinate currently highlighted in the bottom card (pending selection if browsing, else active target).
    public var inspectedLocation: TargetLocation {
        pendingLocation ?? targetLocation
    }

    public var isCurrentInspectedFavorite: Bool {
        let loc = inspectedLocation
        return favorites.contains {
            abs($0.latitude - loc.latitude) < 1e-4 && abs($0.longitude - loc.longitude) < 1e-4
        }
    }

    public func selectLocationFromMap(_ mapCoord: CLLocationCoordinate2D, name: String? = nil, address: String? = nil) {
        let wgs = fromMapCoordinate(mapCoord)
        selectWGSLocation(
            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: name,
            address: address,
            resolveAltitude: true
        )
    }

    public func selectWGSLocation(
        _ wgsLoc: TargetLocation,
        name: String? = nil,
        address: String? = nil,
        resolveAltitude: Bool = false
    ) {
        if snapshot.isRunning {
            // Keep active reported location unchanged until user taps "更新到此位置".
            pendingLocation = wgsLoc
        } else {
            pendingLocation = nil
            targetLocation = wgsLoc
        }

        if let name, !name.isEmpty {
            selectedPlaceName = name
            selectedPlaceAddress = address ?? String(format: "%.5f, %.5f", wgsLoc.latitude, wgsLoc.longitude)
        } else {
            selectedPlaceName = String(format: "%.5f, %.5f", wgsLoc.latitude, wgsLoc.longitude)
            selectedPlaceAddress = L10n.tr("map.geocoding")
            reverseGeocode(wgsLocation: wgsLoc)
        }

        if resolveAltitude {
            resolveElevation(for: wgsLoc)
        } else {
            cancelElevationResolution()
        }
    }

    public func clearPendingSelection() {
        pendingLocation = nil
        cancelElevationResolution()
        reverseGeocode(wgsLocation: targetLocation)
    }

    public func applyPendingLocationUpdate() {
        guard let pending = pendingLocation else { return }
        let wasConfirmed = isAccessoryLocationConfirmed
        targetLocation = pending
        pendingLocation = nil
        isAccessoryLocationConfirmed = false
        consecutiveLockLossCount = 0
        resetDeadReckoningTracker()
        needsLocationServiceRefresh = false
        lastAutoReconnectAt = 0
        session?.notifyLocationUpdated(resetKalman: wasConfirmed, burstSeconds: 10.0)
        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        if snapshot.isRunning {
            updateInjectionPhase()
            scheduleLockWatchdog()
        }
    }

    // MARK: - Automatic Terrain Elevation Lookup

    private func cancelElevationResolution() {
        elevationTask?.cancel()
        elevationTask = nil
        elevationGeneration += 1
        isResolvingAltitude = false
    }

    private func resolveElevation(for wgsLocation: TargetLocation) {
        elevationTask?.cancel()
        elevationGeneration += 1
        let gen = elevationGeneration
        let lat = wgsLocation.latitude
        let lon = wgsLocation.longitude
        isResolvingAltitude = true

        elevationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.elevationGeneration == gen {
                    self.isResolvingAltitude = false
                }
            }

            var resolved = await self.fetchElevationWithOpenMeteo(latitude: lat, longitude: lon)
            if resolved == nil && !Task.isCancelled {
                resolved = await self.fetchElevationWithOpenTopoData(latitude: lat, longitude: lon)
            }
            guard !Task.isCancelled, self.elevationGeneration == gen, let altitude = resolved else { return }
            let rounded = (min(50_000.0, max(-500.0, altitude)) * 10.0).rounded() / 10.0
            self.applyResolvedAltitude(rounded, forLatitude: lat, longitude: lon)
        }
    }

    private func applyResolvedAltitude(_ altitude: Double, forLatitude lat: Double, longitude lon: Double) {
        if var pending = pendingLocation,
           abs(pending.latitude - lat) < 1e-6,
           abs(pending.longitude - lon) < 1e-6 {
            pending.altitude = altitude
            pendingLocation = pending
            return
        }
        if abs(targetLocation.latitude - lat) < 1e-6,
           abs(targetLocation.longitude - lon) < 1e-6 {
            var updated = targetLocation
            updated.altitude = altitude
            targetLocation = updated
            if snapshot.isRunning {
                persistRecoveryRecord()
            }
        }
    }

    private func fetchElevationWithOpenMeteo(latitude: Double, longitude: Double) async -> Double? {
        let latStr = String(format: "%.6f", latitude)
        let lonStr = String(format: "%.6f", longitude)
        guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(latStr)&longitude=\(lonStr)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = json["elevation"] as? [NSNumber],
                  let first = values.first else {
                return nil
            }
            let alt = first.doubleValue
            return alt.isFinite ? alt : nil
        } catch {
            return nil
        }
    }

    private func fetchElevationWithOpenTopoData(latitude: Double, longitude: Double) async -> Double? {
        let latStr = String(format: "%.6f", latitude)
        let lonStr = String(format: "%.6f", longitude)
        guard let url = URL(string: "https://api.opentopodata.org/v1/aster30m?locations=\(latStr),\(lonStr)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let elev = first["elevation"] as? NSNumber else {
                return nil
            }
            let alt = elev.doubleValue
            return alt.isFinite ? alt : nil
        } catch {
            return nil
        }
    }

    private func reverseGeocode(wgsLocation: TargetLocation) {
        geocoder.cancelGeocode()
        geocodeTask?.cancel()
        geocodeGeneration += 1
        let gen = geocodeGeneration
        let coordText = String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)

        geocodeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 1. Try system CLGeocoder first (strict 2.0s non-blocking timeout so China GeoServices never hangs on overseas coords).
            if let resolved = await self.reverseGeocodeWithCLGeocoder(wgsLocation: wgsLocation, timeoutSeconds: 2.0) {
                guard !Task.isCancelled, self.geocodeGeneration == gen else { return }
                self.selectedPlaceName = resolved.title
                self.selectedPlaceAddress = resolved.address
                return
            }
            guard !Task.isCancelled, self.geocodeGeneration == gen else { return }

            // 2. Fallback to free keyless OpenStreetMap Nominatim (pure WGS-84, street-level detail).
            if let resolved = await self.reverseGeocodeWithNominatim(wgsLocation: wgsLocation) {
                guard !Task.isCancelled, self.geocodeGeneration == gen else { return }
                self.selectedPlaceName = resolved.title
                self.selectedPlaceAddress = resolved.address
                return
            }
            guard !Task.isCancelled, self.geocodeGeneration == gen else { return }

            // 3. Fallback to free keyless BigDataCloud reverse geocoder (CDN-backed, works reliably in China & globally).
            if let resolved = await self.reverseGeocodeWithBigDataCloud(wgsLocation: wgsLocation) {
                guard !Task.isCancelled, self.geocodeGeneration == gen else { return }
                self.selectedPlaceName = resolved.title
                self.selectedPlaceAddress = resolved.address
                return
            }
            guard !Task.isCancelled, self.geocodeGeneration == gen else { return }

            // 4. Final fallback: never leave geocoding placeholder stuck on screen.
            self.selectedPlaceName = coordText
            self.selectedPlaceAddress = L10n.tr("map.wgs84_coord")
        }
    }

    private func reverseGeocodeWithCLGeocoder(
        wgsLocation: TargetLocation,
        timeoutSeconds: TimeInterval
    ) async -> (title: String, address: String)? {
        let clLoc = CLLocation(latitude: wgsLocation.latitude, longitude: wgsLocation.longitude)
        let geocoder = self.geocoder
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: (String, String)?) {
                lock.lock()
                let shouldResume = !resumed
                resumed = true
                lock.unlock()
                if shouldResume {
                    continuation.resume(returning: value)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                lock.lock()
                let stillPending = !resumed
                lock.unlock()
                if stillPending {
                    geocoder.cancelGeocode()
                    finish(nil)
                }
            }

            let preferredLocale: Locale? = L10n.currentLanguage == .system ? nil : L10n.currentLanguage.locale
            geocoder.reverseGeocodeLocation(clLoc, preferredLocale: preferredLocale) { placemarks, _ in
                guard let pm = placemarks?.first else {
                    finish(nil)
                    return
                }
                let title = pm.name ?? pm.locality ?? pm.administrativeArea
                    ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                let parts = [pm.country, pm.administrativeArea, pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { acc, item in
                        if !acc.contains(item) { acc.append(item) }
                    }
                let addr = parts.isEmpty
                    ? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                    : parts.joined(separator: " ")
                finish((title, addr))
            }
        }
    }

    private func reverseGeocodeWithNominatim(
        wgsLocation: TargetLocation
    ) async -> (title: String, address: String)? {
        let latStr = String(format: "%.6f", wgsLocation.latitude)
        let lonStr = String(format: "%.6f", wgsLocation.longitude)
        let acceptLang = L10n.nominatimAcceptLanguage
        guard let url = URL(string: "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=\(latStr)&lon=\(lonStr)&zoom=18&addressdetails=1&accept-language=\(acceptLang)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let addrDict = json["address"] as? [String: Any] ?? [:]
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (addrDict["road"] as? String)
                ?? (addrDict["neighbourhood"] as? String)
                ?? (addrDict["suburb"] as? String)
                ?? (addrDict["city"] as? String)
                ?? (addrDict["town"] as? String)
                ?? (addrDict["county"] as? String)
                ?? (addrDict["state"] as? String)

            let displayName = (json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = [
                addrDict["country"] as? String,
                addrDict["state"] as? String,
                (addrDict["city"] as? String) ?? (addrDict["town"] as? String) ?? (addrDict["county"] as? String),
                (addrDict["suburb"] as? String) ?? (addrDict["neighbourhood"] as? String),
                addrDict["road"] as? String,
                addrDict["house_number"] as? String,
            ].compactMap { $0 }.reduce(into: [String]()) { acc, item in
                if !item.isEmpty && !acc.contains(item) { acc.append(item) }
            }

            let resolvedTitle = name ?? displayName ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
            let resolvedAddress = !parts.isEmpty
                ? parts.joined(separator: " ")
                : (displayName ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude))
            return (resolvedTitle, resolvedAddress)
        } catch {
            return nil
        }
    }

    private func reverseGeocodeWithBigDataCloud(
        wgsLocation: TargetLocation
    ) async -> (title: String, address: String)? {
        let latStr = String(format: "%.6f", wgsLocation.latitude)
        let lonStr = String(format: "%.6f", wgsLocation.longitude)
        let lang = L10n.bigDataCloudLanguage
        guard let url = URL(string: "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=\(latStr)&longitude=\(lonStr)&localityLanguage=\(lang)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let country = json["countryName"] as? String
            let subdivision = json["principalSubdivision"] as? String
            let city = json["city"] as? String
            let locality = json["locality"] as? String

            let parts = [country, subdivision, city, locality]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .reduce(into: [String]()) { acc, item in
                    if !item.isEmpty && !acc.contains(item) { acc.append(item) }
                }
            guard !parts.isEmpty else { return nil }
            let title = locality.flatMap { $0.isEmpty ? nil : $0 }
                ?? city.flatMap { $0.isEmpty ? nil : $0 }
                ?? subdivision.flatMap { $0.isEmpty ? nil : $0 }
                ?? parts.last!
            return (title, parts.joined(separator: " "))
        } catch {
            return nil
        }
    }

    // MARK: - Live Coordinate Sync

    private func pushLocationToSession() {
        session?.locationBox.set(targetLocation)
    }

    // MARK: - Interrupted Session Recovery

    public func resumeInterruptedSession() {
        guard let record = interruptedSession, !snapshot.isRunning else { return }
        targetLocation = TargetLocation(latitude: record.latitude, longitude: record.longitude, altitude: record.altitude)
        selectedPlaceName = record.placeName
        pendingLocation = nil
        start(mode: .send)
    }

    public func dismissInterruptedSession() {
        interruptedSession = nil
        store.saveInterruptedSession(nil)
    }

    private func persistRecoveryRecord() {
        let rec = InterruptedSessionRecord(
            placeName: selectedPlaceName,
            latitude: targetLocation.latitude,
            longitude: targetLocation.longitude,
            altitude: targetLocation.altitude
        )
        store.saveInterruptedSession(rec)
    }

    // MARK: - Session Readiness

    public var canStartSession: Bool {
        mfiSigner != nil && !snapshot.isRunning
    }

    // MARK: - Location Injection Session

    public func start(mode: SessionMode, durationOverrideSeconds: TimeInterval? = nil) {
        startSessionInternal(
            mode: mode,
            trajectoryDriver: nil,
            joystickDriver: nil,
            durationOverrideSeconds: durationOverrideSeconds
        )
    }

    public func startRouteSession(durationOverrideSeconds: TimeInterval? = nil) {
        guard !snapshot.isRunning, plannedRoutePoints.count >= 2 else { return }
        isFreehandDrawing = false
        guard let driver = TrajectoryDriver(
            points: plannedRoutePoints,
            preset: routePreset,
            speedMetersPerSecond: routeSpeedMps,
            loopMode: routeLoopMode,
            realisticMotionEnabled: routeRealisticMotionEnabled,
            waitForStartLock: true,
            initialProgress: routeStartProgress,
            targetTotalDistanceMeters: effectiveRouteTargetDistanceMeters,
            targetLaps: effectiveRouteTargetLaps,
            briefStopsEnabled: routeBriefStopsEnabled
        ) else { return }

        let startLoc = driver.currentTargetLocation()
        targetLocation = startLoc
        pendingLocation = nil
        if !freehandBasePoints.isEmpty {
            selectedPlaceName = importedRouteTitle ?? "\(L10n.tr("route.creation.freehand")) · \(RouteGeometry.formatDistance(plannedRouteDistanceMeters))"
        } else if let firstName = routeWaypoints.first?.name, let lastName = routeWaypoints.last?.name {
            selectedPlaceName = "\(firstName) → \(lastName)"
        }
        isRouteSessionActive = true
        isJoystickSessionActive = false
        joystickProgress = nil
        joystickCruiseLocked = false
        pendingBackgroundJoystickProgress = nil
        trajectoryProgress = driver.initialProgress()
        pendingBackgroundTrajectoryProgress = nil
        startSessionInternal(
            mode: .send,
            trajectoryDriver: driver,
            joystickDriver: nil,
            durationOverrideSeconds: durationOverrideSeconds
        )
    }

    public func startJoystickSession(durationOverrideSeconds: TimeInterval? = nil) {
        guard !snapshot.isRunning else { return }
        isFreehandDrawing = false
        if let pending = pendingLocation {
            targetLocation = pending
            pendingLocation = nil
        }
        let driver = JoystickDriver(
            initialLocation: targetLocation,
            maxSpeedMps: joystickSpeedMps,
            realisticMotionEnabled: routeRealisticMotionEnabled,
            waitForStartLock: true
        )
        controlMode = .joystick
        isRouteSessionActive = false
        trajectoryProgress = nil
        pendingBackgroundTrajectoryProgress = nil
        isJoystickSessionActive = true
        joystickCruiseLocked = false
        joystickProgress = driver.initialProgress()
        pendingBackgroundJoystickProgress = nil
        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        startSessionInternal(
            mode: .send,
            trajectoryDriver: nil,
            joystickDriver: driver,
            durationOverrideSeconds: durationOverrideSeconds
        )
    }

    public func updateJoystickInput(magnitude: Double, headingDegrees: Double?) {
        guard isJoystickSessionActive else { return }
        session?.setJoystickVector(magnitude: magnitude, headingDegrees: headingDegrees)
    }

    public func toggleJoystickCruiseLock() {
        guard isJoystickSessionActive else { return }
        joystickCruiseLocked.toggle()
        session?.setJoystickCruiseLocked(joystickCruiseLocked)
        if var prog = joystickProgress {
            prog.isCruiseLocked = joystickCruiseLocked
            joystickProgress = prog
        }
    }

    private func startSessionInternal(
        mode: SessionMode,
        trajectoryDriver: TrajectoryDriver?,
        joystickDriver: JoystickDriver?,
        durationOverrideSeconds: TimeInterval? = nil
    ) {
        guard !snapshot.isRunning else { return }
        guard let mfiSigner else {
            alertMessage = L10n.tr("error.mfi_unavailable")
            isRouteSessionActive = false
            trajectoryProgress = nil
            isJoystickSessionActive = false
            joystickProgress = nil
            return
        }

        if trajectoryDriver == nil && joystickDriver == nil {
            isRouteSessionActive = false
            trajectoryProgress = nil
            pendingBackgroundTrajectoryProgress = nil
            isJoystickSessionActive = false
            joystickProgress = nil
            joystickCruiseLocked = false
            pendingBackgroundJoystickProgress = nil
            if let pending = pendingLocation {
                targetLocation = pending
                pendingLocation = nil
            }
            recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
            persistRecoveryRecord()
        }
        interruptedSession = nil

        let effectiveDuration = durationOverrideSeconds ?? durationSeconds
        let config = SessionConfiguration(
            mode: mode,
            intervalSeconds: intervalSeconds,
            durationSeconds: mode == .probe ? max(20.0, effectiveDuration) : effectiveDuration
        )

        isAccessoryLocationConfirmed = false
        consecutiveLockLossCount = 0
        resetDeadReckoningTracker()
        needsLocationServiceRefresh = false
        isLocationRefreshGuideActive = false
        lastAutoReconnectAt = 0
        pendingBackgroundSnapshot = nil
        loggedReducedAccuracyForSession = false
        cancelRestoreRecovery()
        injectionPhase = .connecting
        cancelTriggerTasks()

        // Arm a temporary OS background task until iAP2 auth completes and activates pure CoreLocation
        // background keep-alive (no silent audio playback, no internal GPS wake before auth).
        keepAlive.prepareForSession()

        let sessionID = UUID()
        let newSession = AccessoryLocationSession(
            id: sessionID,
            initialLocation: targetLocation,
            microJitterEnabled: microJitterEnabled,
            trajectoryDriver: trajectoryDriver,
            joystickDriver: joystickDriver,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.events.append(event)
                    if self.events.count > 500 {
                        self.events.removeFirst(self.events.count - 500)
                    }
                }
            },
            onSnapshot: { [weak self] snap in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    let stateChanged = self.snapshot.isRunning != snap.isRunning
                        || self.snapshot.linkReady != snap.linkReady
                        || self.snapshot.identified != snap.identified
                        || self.snapshot.authenticated != snap.authenticated
                        || self.snapshot.activeSentences != snap.activeSentences
                        || self.snapshot.lastError != snap.lastError

                    if self.isAppInForeground || stateChanged || !self.isAccessoryLocationConfirmed {
                        self.pendingBackgroundSnapshot = nil
                        self.snapshot = snap
                        self.updateInjectionPhase()
                    } else {
                        self.pendingBackgroundSnapshot = snap
                    }

                    if !snap.isRunning {
                        self.session = nil
                        self.pendingBackgroundSnapshot = nil
                        self.pendingBackgroundTrajectoryProgress = nil
                        self.pendingBackgroundJoystickProgress = nil
                        self.isRouteSessionActive = false
                        self.trajectoryProgress = nil
                        self.isJoystickSessionActive = false
                        self.joystickProgress = nil
                        self.joystickCruiseLocked = false
                        self.cancelTriggerTasks()
                        self.keepAlive.stop()
                        self.coreLocation.setExternalFeedActive(false)
                        self.interruptedSession = self.store.loadInterruptedSession()
                        if !self.isRestoringRealLocation {
                            self.coreLocation.stop()
                        }
                        self.isAccessoryLocationConfirmed = false
                        self.needsLocationServiceRefresh = false
                        self.injectionPhase = .idle
                        if self.isLocationRefreshGuideActive {
                            self.isLocationRefreshGuideActive = false
                            LocationRefreshPresenter.shared.finishLocationRefresh(succeeded: false, message: L10n.tr("pip.finish.stopped.message"))
                        }
                    }
                }
            },
            onTrajectoryProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    let importantTransition = self.trajectoryProgress?.isCompleted != progress.isCompleted
                        || self.trajectoryProgress?.isWaitingForStartLock != progress.isWaitingForStartLock
                        || self.trajectoryProgress?.lapCount != progress.lapCount
                        || self.trajectoryProgress?.isPaused != progress.isPaused
                        || self.trajectoryProgress?.isBriefStopping != progress.isBriefStopping
                    if self.isAppInForeground || importantTransition {
                        self.pendingBackgroundTrajectoryProgress = nil
                        self.trajectoryProgress = progress
                    } else {
                        self.pendingBackgroundTrajectoryProgress = progress
                    }
                }
            },
            onJoystickProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    let importantTransition = self.joystickProgress?.isWaitingForStartLock != progress.isWaitingForStartLock
                        || self.joystickProgress?.isCruiseLocked != progress.isCruiseLocked
                        || self.joystickProgress?.isMoving != progress.isMoving
                    if self.isAppInForeground || importantTransition {
                        self.pendingBackgroundJoystickProgress = nil
                        self.joystickProgress = progress
                    } else {
                        self.pendingBackgroundJoystickProgress = progress
                    }
                }
            },
            onAuthenticated: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.handleSessionAuthenticated()
                }
            },
            onLocationRequested: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.handleLocationSubscribed()
                }
            },
            onLocationStopped: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.handleLocationStoppedBySystem()
                }
            },
            onSubscriptionRestarted: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.keepAlive.refreshAfterLocationToggle()
                }
            },
            onReconnecting: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.keepAlive.beginTransientBackgroundBridge(reason: "Reloc.Reconnect")
                }
            }
        )
        newSession.setFallbackRealLocation(lastKnownRealLocation)
        self.session = newSession
        snapshot.isRunning = true
        newSession.start(configuration: config, mfiSigner: mfiSigner)
    }

    public func stopAndRestore() {
        cancelTriggerTasks()
        let activeSession = session
        session = nil
        pendingBackgroundSnapshot = nil
        pendingBackgroundTrajectoryProgress = nil
        pendingBackgroundJoystickProgress = nil
        isRouteSessionActive = false
        trajectoryProgress = nil
        isJoystickSessionActive = false
        joystickProgress = nil
        joystickCruiseLocked = false
        activeSession?.stop()
        keepAlive.stop()
        coreLocation.setExternalFeedActive(false)
        snapshot.isRunning = false
        snapshot.activeSentences = []
        isAccessoryLocationConfirmed = false
        consecutiveLockLossCount = 0
        resetDeadReckoningTracker()
        needsLocationServiceRefresh = false
        injectionPhase = .idle
        if isLocationRefreshGuideActive {
            isLocationRefreshGuideActive = false
            LocationRefreshPresenter.shared.teardown()
        }
        store.saveInterruptedSession(nil)
        interruptedSession = nil
        beginRealLocationRecovery()
    }

    // MARK: - Post-Stop Real GPS Recovery

    private func cancelRestoreRecovery() {
        restoreTask?.cancel()
        restoreTask = nil
        isRestoringRealLocation = false
        needsRestoreLocationRefresh = false
        realLocationRestoredNotice = false
        if isRestoreRefreshGuideActive {
            isRestoreRefreshGuideActive = false
            LocationRefreshPresenter.shared.teardown()
        }
    }

    private func beginRealLocationRecovery() {
        restoreTask?.cancel()
        isRestoringRealLocation = true
        needsRestoreLocationRefresh = false
        realLocationRestoredNotice = false
        lastRestoreAuthStatus = coreLocation.authorizationStatus

        restoreTask = Task { @MainActor [weak self] in
            // Wait briefly for Void NMEA (GGA quality=0 / RMC status=V) + iAP2 RST + tunnel close to flush.
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self, !self.snapshot.isRunning else { return }

            // Actively request fresh internal GNSS/Wi-Fi/Cell fix so `locationd` flushes the cached accessory fix.
            self.coreLocation.requestAndStart()
            self.coreLocation.pulseForAccessoryLock(requestSingleFix: true)
            self.events.append(ProtocolEvent(
                name: "real_location_recovery_started",
                detail: "{\"event\":\"real_location_recovery_started\"}"
            ))

            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            self.coreLocation.pulseForAccessoryLock(requestSingleFix: true)

            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            // Indoors / weak GNSS: offer 1-tap PiP Location Services flush to guarantee instant restoration.
            self.needsRestoreLocationRefresh = true

            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            if !self.isRestoreRefreshGuideActive {
                self.coreLocation.stop()
                self.isRestoringRealLocation = false
            }
        }
    }

    private func handleCoreLocationAuthChangeForRestore(_ status: CLAuthorizationStatus) {
        let prev = lastRestoreAuthStatus
        lastRestoreAuthStatus = status

        // Active injection refresh guide: react directly to real system Location Services OFF/ON transitions.
        if isLocationRefreshGuideActive && snapshot.isRunning {
            if status == .denied || status == .restricted {
                locationStopDebounceTask?.cancel()
                locationStopDebounceTask = nil
                if !locationRefreshSawDisabled {
                    locationRefreshSawDisabled = true
                    startLocationRefreshCountdown()
                }
            } else if locationRefreshSawDisabled,
                      (prev == .denied || prev == .restricted),
                      (status == .authorizedAlways || status == .authorizedWhenInUse) {
                refreshCountdownTask?.cancel()
                refreshCountdownTask = nil
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 3,
                    headline: L10n.tr("pip.step3.reopened.headline"),
                    subtitle: L10n.tr("pip.step3.reopened.subtitle")
                )
                session?.triggerFastBurst(seconds: 25.0)
                schedulePostRefreshRecoveryWatchdog()
            }
            return
        }

        guard isRestoreRefreshGuideActive else { return }

        if status == .denied || status == .restricted {
            // User just toggled Location Services OFF -> start 5s countdown in PiP!
            startRestoreRefreshCountdown()
        } else if (prev == .denied || prev == .restricted)
            && (status == .authorizedAlways || status == .authorizedWhenInUse) {
            refreshCountdownTask?.cancel()
            refreshCountdownTask = nil
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: L10n.tr("pip.step3.restoring.headline"),
                subtitle: L10n.tr("pip.step3.restoring.subtitle")
            )
            coreLocation.requestAndStart()
            coreLocation.pulseForAccessoryLock(requestSingleFix: true)
        }
    }

    public func launchOneTapRestoreRefresh(skipAutoSettingsJump: Bool = false) {
        restoreTask?.cancel()
        restoreTask = nil
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        isRestoreRefreshGuideActive = true
        isRestoringRealLocation = true
        lastRestoreAuthStatus = coreLocation.authorizationStatus
        LocationRefreshPresenter.shared.startLocationRefreshGuide(countdownSeconds: 7, isDistant: false)
        LocationRefreshPresenter.shared.updateLocationRefresh(
            step: 1,
            headline: L10n.tr("pip.step1.headline"),
            subtitle: L10n.tr("pip.step1.restore.subtitle")
        )
        guard !skipAutoSettingsJump else { return }
        // Let PiP enter smoothly before switching apps to Settings (avoids transition stutter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isRestoreRefreshGuideActive else { return }
            self.openLocationServicesSettings()
        }
    }

    private func startRestoreRefreshCountdown() {
        refreshCountdownTask?.cancel()
        let countdownTotal = 7
        refreshCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: countdownTotal, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.isRestoreRefreshGuideActive else { return }
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 2,
                    headline: L10n.tr("pip.step2.restore.headline"),
                    subtitle: L10n.tr("pip.step2.subtitle"),
                    countdown: remaining
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self, self.isRestoreRefreshGuideActive else { return }
            RelocTheme.hapticMedium()
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: L10n.tr("pip.step3.enable.headline"),
                subtitle: L10n.tr("pip.step3.restore.subtitle"),
                countdown: 0
            )
        }
    }

    // MARK: - Fast-Lock Auto-Trigger & One-Tap PiP Location Refresh

    private func cancelTriggerTasks() {
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = nil
        lockWatchdogTask?.cancel()
        lockWatchdogTask = nil
        postRefreshRecoveryTask?.cancel()
        postRefreshRecoveryTask = nil
        unexpectedStopRecoveryTask?.cancel()
        unexpectedStopRecoveryTask = nil
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        locationStopDebounceTask?.cancel()
        locationStopDebounceTask = nil
        locationRefreshSawDisabled = false
    }

    private func canTriggerAutoReconnect() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return lastAutoReconnectAt == 0 || (now - lastAutoReconnectAt) >= autoReconnectCooldownSeconds
    }

    private func handleSessionAuthenticated(forceRestartLocation: Bool = true) {
        guard snapshot.isRunning else { return }
        // Route LiveCoreLocationMonitor through BackgroundKeepAlive's single CLLocationManager
        // to avoid running two simultaneous navigation-grade CoreLocation consumers.
        coreLocation.setExternalFeedActive(true)
        // Activate navigation-grade CoreLocation right AFTER iAP2 auth succeeds so `locationd`
        // immediately pairs this fresh request with our authenticated external MFi GPS accessory.
        keepAlive.activateLocationSubscription(forceRestart: forceRestartLocation)
        updateInjectionPhase()

        // Escalating wake-up strategy if `locationd` doesn't dispatch 0xFFFA promptly:
        // 1–2: non-destructive accuracy-tier nudge (avoids dropping active consumers to 0)
        // 3: hard CoreLocation pulse
        // 4: cooldown-guarded iAP2 link reconnect to clear stale `iap2d` state, then surface 1-tap refresh.
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = Task { @MainActor [weak self] in
            for attempt in 1...3 {
                let delayNs: UInt64 = attempt == 1 ? 1_500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
                if !self.snapshot.activeSentences.isEmpty { return }
                self.events.append(ProtocolEvent(
                    name: "auto_subscription_pulse",
                    detail: "{\"event\":\"auto_subscription_pulse\",\"attempt\":\(attempt),\"mode\":\"\(attempt < 3 ? "nudge" : "pulse")\"}"
                ))
                if attempt < 3 {
                    self.keepAlive.nudgeLocationSubscription()
                } else {
                    self.keepAlive.pulseLocationSubscription()
                }
            }

            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
            if !self.snapshot.activeSentences.isEmpty { return }

            if self.canTriggerAutoReconnect() {
                self.lastAutoReconnectAt = ProcessInfo.processInfo.systemUptime
                self.events.append(ProtocolEvent(
                    name: "auto_subscription_reconnect",
                    detail: "{\"event\":\"auto_subscription_reconnect\"}"
                ))
                self.session?.requestLinkReconnect(reason: "waiting_subscription_timeout")
            } else {
                self.needsLocationServiceRefresh = true
            }
        }
    }

    private func handleLocationSubscribed() {
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = nil
        unexpectedStopRecoveryTask?.cancel()
        unexpectedStopRecoveryTask = nil
        locationStopDebounceTask?.cancel()
        locationStopDebounceTask = nil
        updateInjectionPhase()

        if isLocationRefreshGuideActive {
            if locationRefreshSawDisabled {
                refreshCountdownTask?.cancel()
                refreshCountdownTask = nil
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 3,
                    headline: L10n.tr("pip.step3.subscribed.headline"),
                    subtitle: L10n.tr("pip.step3.subscribed.subtitle")
                )
                session?.triggerFastBurst(seconds: 25.0)
                schedulePostRefreshRecoveryWatchdog()
            }
            return
        }
        scheduleLockWatchdog()
    }

    private func handleLocationStoppedBySystem() {
        isAccessoryLocationConfirmed = false
        consecutiveLockLossCount = 0
        resetDeadReckoningTracker()
        session?.markCoreLocationConfirmed(false)
        updateInjectionPhase()

        // Debounce 0xFFFC by 0.9s during PiP refresh so transient app-switch hiccups never falsely
        // start the countdown before the user actually toggles Location Services off.
        if isLocationRefreshGuideActive && !locationRefreshSawDisabled {
            locationStopDebounceTask?.cancel()
            locationStopDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.isLocationRefreshGuideActive,
                      !self.locationRefreshSawDisabled,
                      self.snapshot.isRunning,
                      self.snapshot.activeSentences.isEmpty else { return }
                self.locationRefreshSawDisabled = true
                self.startLocationRefreshCountdown()
            }
            return
        }

        // Unexpected 0xFFFC during a multi-hour background session: debounce briefly, then
        // wake 0xFFFA non-destructively (never dropping the background location assertion).
        if !isLocationRefreshGuideActive && snapshot.isRunning {
            unexpectedStopRecoveryTask?.cancel()
            unexpectedStopRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.snapshot.isRunning,
                      !self.isLocationRefreshGuideActive,
                      self.snapshot.activeSentences.isEmpty else { return }
                self.events.append(ProtocolEvent(
                    name: "auto_subscription_recovery_after_stop",
                    detail: "{\"event\":\"auto_subscription_recovery_after_stop\"}"
                ))
                self.handleSessionAuthenticated(forceRestartLocation: false)
            }
        }
    }

    private func scheduleLockWatchdog() {
        lockWatchdogTask?.cancel()
        lockWatchdogTask = Task { @MainActor [weak self] in
            // Stage 1 (2.0s): boost valid NMEA stream to 5 Hz + non-destructive CoreLocation nudge.
            // Never emit void NMEA (quality=0) or tear down an active 0xFFFA endpoint here, as doing so
            // drops external GPS authority and causes CLNMEAScreener to lock onto real Wi-Fi/Cell fixes.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                self.events.append(ProtocolEvent(
                    name: "auto_lock_nudge",
                    detail: "{\"event\":\"auto_lock_nudge\"}"
                ))
                self.session?.triggerFastBurst(seconds: 12.0)
                self.keepAlive.nudgeLocationSubscription()
            }

            // Stage 2 (5.0s): second non-destructive nudge while keeping the healthy 0xFFFA stream unbroken.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                self.session?.triggerFastBurst(seconds: 10.0)
                self.keepAlive.nudgeLocationSubscription()
            }

            // Stage 3 (8.0s): if valid NMEA has been ACKed for 8s without confirmation, CLNMEAScreener
            // is blocking the jump — surface the 1-tap Location Services refresh banner cleanly.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                self.needsLocationServiceRefresh = true
            }
        }
    }

    private func resetDeadReckoningTracker() {
        lastAccessoryVerticalAccuracy = nil
        consecutiveVertAccIncreases = 0
        lastAccessoryReportedCoordinate = nil
    }

    private func evaluateCoreLocationConfirmation(_ telemetry: LiveLocationTelemetry?) {
        if let telemetry, telemetry.isProducedByAccessory == false {
            let real = TargetLocation(latitude: telemetry.latitude, longitude: telemetry.longitude, altitude: telemetry.altitude)
            lastKnownRealLocation = real
            session?.setFallbackRealLocation(real)
            let shouldPersist: Bool
            if let prev = lastPersistedRealLocation {
                shouldPersist = RouteGeometry.distanceMeters(
                    lat1: prev.latitude,
                    lon1: prev.longitude,
                    lat2: real.latitude,
                    lon2: real.longitude
                ) > 50.0
            } else {
                shouldPersist = true
            }
            if shouldPersist {
                lastPersistedRealLocation = real
                store.saveCachedRealLocation(real)
            }
        }
        // Post-stop recovery check: wait until `locationd` delivers a fresh internal (non-accessory) fix.
        if isRestoringRealLocation && !snapshot.isRunning {
            guard let telemetry else { return }
            let isFresh = abs(telemetry.timestamp.timeIntervalSinceNow) < 15.0
            if isFresh && telemetry.isProducedByAccessory == false {
                restoreTask?.cancel()
                restoreTask = nil
                isRestoringRealLocation = false
                needsRestoreLocationRefresh = false
                realLocationRestoredNotice = true
                coreLocation.stop()
                RelocTheme.hapticSuccess()
                events.append(ProtocolEvent(
                    name: "real_location_restored",
                    detail: String(format: "{\"event\":\"real_location_restored\",\"lat\":%.5f,\"lon\":%.5f,\"accuracy_m\":%.1f}", telemetry.latitude, telemetry.longitude, telemetry.horizontalAccuracy)
                ))
                if isRestoreRefreshGuideActive {
                    isRestoreRefreshGuideActive = false
                    refreshCountdownTask?.cancel()
                    refreshCountdownTask = nil
                    LocationRefreshPresenter.shared.finishLocationRefresh(
                        succeeded: true,
                        message: L10n.tr("pip.finish.restored.message"),
                        headline: L10n.tr("pip.finish.restored.headline")
                    )
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self?.realLocationRestoredNotice = false
                }
            }
            return
        }

        guard snapshot.isRunning, let telemetry else {
            if !snapshot.isRunning {
                isAccessoryLocationConfirmed = false
                resetDeadReckoningTracker()
            }
            return
        }
        if coreLocation.isReducedAccuracy && !loggedReducedAccuracyForSession {
            loggedReducedAccuracyForSession = true
            events.append(ProtocolEvent(
                name: "reduced_accuracy_detected",
                detail: "{\"event\":\"reduced_accuracy_detected\"}",
                isError: true
            ))
        }
        let expectedLoc = session?.currentComparisonLocation() ?? targetLocation
        let targetCL = CLLocation(latitude: expectedLoc.latitude, longitude: expectedLoc.longitude)
        let reportedCL = CLLocation(latitude: telemetry.latitude, longitude: telemetry.longitude)
        let distance = targetCL.distance(from: reportedCL)
        let isFreshFix = abs(telemetry.timestamp.timeIntervalSinceNow) < 10.0

        // Detect iOS `locationd` @ClxADL dead-reckoning propagation when `CLNmeaScreener` rejects NMEA:
        // locationd keeps emitting `isProducedByAccessory == true` at the frozen prior coordinate while
        // `verticalAccuracy` inflates monotonically (~0.5 m/s) past 20 m.
        var isDeadReckoningFrozen = false
        if telemetry.isProducedByAccessory == true {
            let movedMeters: Double
            if let prevCoord = lastAccessoryReportedCoordinate {
                movedMeters = RouteGeometry.distanceMeters(
                    lat1: prevCoord.latitude,
                    lon1: prevCoord.longitude,
                    lat2: telemetry.latitude,
                    lon2: telemetry.longitude
                )
            } else {
                movedMeters = 0.0
            }
            let moveFloorMeters = (isRouteSessionActive || isJoystickSessionActive) ? 0.5 : 1.5
            if movedMeters >= moveFloorMeters {
                consecutiveVertAccIncreases = 0
            } else if telemetry.verticalAccuracy >= 0, let prevVert = lastAccessoryVerticalAccuracy {
                if telemetry.verticalAccuracy > prevVert + 0.05 {
                    consecutiveVertAccIncreases += 1
                } else if telemetry.verticalAccuracy < prevVert - 0.1 {
                    consecutiveVertAccIncreases = 0
                }
            }
            lastAccessoryVerticalAccuracy = telemetry.verticalAccuracy >= 0 ? telemetry.verticalAccuracy : nil
            lastAccessoryReportedCoordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            if consecutiveVertAccIncreases >= 6 && telemetry.verticalAccuracy >= 20.0 {
                isDeadReckoningFrozen = true
            }
        } else {
            resetDeadReckoningTracker()
        }

        // Tight distance thresholds prevent stale dead-reckoned pins from falsely confirming a route.
        let maxDistanceMeters: Double
        if isRouteSessionActive {
            let waitingForLock = session?.isTrajectoryWaitingForLock() ?? true
            if waitingForLock {
                maxDistanceMeters = 25.0
            } else if let prog = trajectoryProgress, !prog.isPaused && !prog.isCompleted {
                maxDistanceMeters = max(35.0, prog.currentSpeedMps * 3.5)
            } else {
                maxDistanceMeters = 50.0
            }
        } else if isJoystickSessionActive {
            let waitingForLock = session?.isTrajectoryWaitingForLock() ?? true
            if waitingForLock {
                maxDistanceMeters = 25.0
            } else if let joy = joystickProgress, joy.isMoving {
                maxDistanceMeters = max(40.0, joy.currentSpeedMps * 3.5)
            } else {
                maxDistanceMeters = 55.0
            }
        } else {
            maxDistanceMeters = 80.0
        }

        let hasFreshSessionPackets = isAccessoryLocationConfirmed || snapshot.packetsAcknowledged >= 2
        let confirmed = !snapshot.activeSentences.isEmpty
            && hasFreshSessionPackets
            && isFreshFix
            && (telemetry.isProducedByAccessory == true)
            && !isDeadReckoningFrozen
            && distance < maxDistanceMeters

        if confirmed {
            consecutiveLockLossCount = 0
        } else if isAccessoryLocationConfirmed {
            consecutiveLockLossCount += 1
            // Tolerate brief transient lag on tight turns (3 misses while still accessory-sourced;
            // 2 misses if internal GPS took over; immediate hold if @ClxADL dead-reckoning froze).
            let requiredMisses = (telemetry.isProducedByAccessory == true) ? 3 : 2
            if !isDeadReckoningFrozen && consecutiveLockLossCount < requiredMisses {
                return
            }
        }

        if confirmed != isAccessoryLocationConfirmed {
            let wasConfirmed = isAccessoryLocationConfirmed
            isAccessoryLocationConfirmed = confirmed
            session?.markCoreLocationConfirmed(confirmed)
            if confirmed {
                needsLocationServiceRefresh = false
                lockWatchdogTask?.cancel()
                lockWatchdogTask = nil
                keepAlive.endTransientBackgroundBridge()
                RelocTheme.hapticSuccess()
                events.append(ProtocolEvent(
                    name: "accessory_location_confirmed",
                    detail: String(format: "{\"event\":\"accessory_location_confirmed\",\"distance_m\":%.1f,\"accuracy_m\":%.1f,\"vert_acc_m\":%.1f,\"alt_m\":%.1f}", distance, telemetry.horizontalAccuracy, telemetry.verticalAccuracy, telemetry.altitude)
                ))
                if isLocationRefreshGuideActive {
                    isLocationRefreshGuideActive = false
                    locationRefreshRetryCount = 0
                    postRefreshRecoveryTask?.cancel()
                    postRefreshRecoveryTask = nil
                    refreshCountdownTask?.cancel()
                    refreshCountdownTask = nil
                    LocationRefreshPresenter.shared.finishLocationRefresh(
                        succeeded: true,
                        message: L10n.format("pip.finish.succeeded.message", selectedPlaceName)
                    )
                }
            } else if wasConfirmed && !isLocationRefreshGuideActive && !snapshot.activeSentences.isEmpty {
                // Mid-session lock drift or `CLNmeaScreener` dead-reckoning freeze: hold trajectory,
                // burst valid NMEA, and surface refresh banner immediately if screening blocked updates.
                let reason = isDeadReckoningFrozen ? "dead_reckoning_screening_block" : "coordinate_drift"
                events.append(ProtocolEvent(
                    name: "accessory_lock_lost",
                    detail: String(format: "{\"event\":\"accessory_lock_lost\",\"reason\":\"%@\",\"distance_m\":%.1f,\"vert_acc_m\":%.1f}", reason, distance, telemetry.verticalAccuracy),
                    isError: isDeadReckoningFrozen
                ))
                session?.triggerFastBurst(seconds: 15.0)
                keepAlive.nudgeLocationSubscription()
                if isDeadReckoningFrozen {
                    needsLocationServiceRefresh = true
                }
                scheduleLockWatchdog()
            }
            updateInjectionPhase()
        } else if !confirmed && isDeadReckoningFrozen && !needsLocationServiceRefresh && !isLocationRefreshGuideActive {
            needsLocationServiceRefresh = true
            events.append(ProtocolEvent(
                name: "accessory_screening_blocked",
                detail: String(format: "{\"event\":\"accessory_screening_blocked\",\"distance_m\":%.1f,\"vert_acc_m\":%.1f}", distance, telemetry.verticalAccuracy),
                isError: true
            ))
            updateInjectionPhase()
        }
    }

    private func updateInjectionPhase() {
        guard snapshot.isRunning else {
            injectionPhase = .idle
            return
        }
        if isAccessoryLocationConfirmed {
            injectionPhase = .activeConfirmed
        } else if !snapshot.activeSentences.isEmpty || snapshot.packetsAcknowledged > 0 {
            injectionPhase = .injectingPendingLock
        } else if snapshot.authenticated {
            injectionPhase = .waitingSubscription
        } else {
            injectionPhase = .connecting
        }
    }

    /// Launches a floating PiP countdown guide and jumps straight to iOS Location Services Settings
    /// for a guaranteed 100% cache flush when `locationd` clings to a stale internal GNSS/Wi-Fi fix.
    public func launchOneTapLocationRefresh(skipAutoSettingsJump: Bool = false) {
        guard snapshot.isRunning else { return }
        // Cancel background pulse/watchdog tasks immediately so they never stop CLLocationManager
        // and falsely trigger a 0xFFFC countdown before the user touches Location Services.
        cancelTriggerTasks()
        let countdown = effectiveRefreshCountdownSeconds
        let distant = isDistantFromRealLocation || isInspectedLocationDistant
        // Acquire a temporary OS background task (~25–30s) paired with PiP to bridge the
        // Location Services OFF window without playing any silent audio.
        keepAlive.beginTransientBackgroundBridge(reason: "Reloc.LocationRefresh")
        isLocationRefreshGuideActive = true
        locationRefreshSawDisabled = false
        locationRefreshRetryCount = 0
        lastRestoreAuthStatus = coreLocation.authorizationStatus
        LocationRefreshPresenter.shared.startLocationRefreshGuide(countdownSeconds: countdown, isDistant: distant)
        session?.triggerFastBurst(seconds: max(60.0, Double(countdown) + 40.0))
        guard !skipAutoSettingsJump else { return }
        // Wait briefly for PiP to enter smoothly before switching to Settings (prevents stutter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isLocationRefreshGuideActive, self.snapshot.isRunning else { return }
            self.openLocationServicesSettings()
        }
    }

    private func handleRefreshGuideClosed() {
        let wasActive = isLocationRefreshGuideActive
        isLocationRefreshGuideActive = false
        isRestoreRefreshGuideActive = false
        locationRefreshSawDisabled = false
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        postRefreshRecoveryTask?.cancel()
        postRefreshRecoveryTask = nil
        if wasActive && snapshot.isRunning && !isAccessoryLocationConfirmed {
            if snapshot.activeSentences.isEmpty {
                handleSessionAuthenticated(forceRestartLocation: false)
            } else {
                scheduleLockWatchdog()
            }
        }
    }

    /// Actively monitors lock acquisition after the user re-enables Location Services inside the PiP guide.
    /// Wakes stalled 0xFFFA subscriptions after long 18–30s OFF windows, nudges CoreLocation, and allows
    /// an immediate in-place longer retry if distant cache still resisted the first toggle.
    private func schedulePostRefreshRecoveryWatchdog() {
        postRefreshRecoveryTask?.cancel()
        postRefreshRecoveryTask = Task { @MainActor [weak self] in
            // 2.5s: if 0xFFFA hasn't returned yet after a long Location Services OFF window, wake it.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, self.snapshot.isRunning, self.isLocationRefreshGuideActive else { return }
            if self.isAccessoryLocationConfirmed { return }
            if self.snapshot.activeSentences.isEmpty {
                self.events.append(ProtocolEvent(
                    name: "post_refresh_wake_subscription",
                    detail: "{\"event\":\"post_refresh_wake_subscription\"}"
                ))
                self.keepAlive.refreshAfterLocationToggle()
                self.keepAlive.nudgeLocationSubscription()
            }

            // 4.5s: if subscribed but still unconfirmed, reinforce fast burst + non-destructive nudge.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning, self.isLocationRefreshGuideActive else { return }
            if self.isAccessoryLocationConfirmed { return }
            self.session?.triggerFastBurst(seconds: 20.0)
            self.keepAlive.nudgeLocationSubscription()

            // 7.0s: if 0xFFFA is STILL missing, soft-reconnect the virtual iAP2 link.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning, self.isLocationRefreshGuideActive else { return }
            if self.isAccessoryLocationConfirmed { return }
            if self.snapshot.activeSentences.isEmpty {
                self.events.append(ProtocolEvent(
                    name: "post_refresh_soft_reconnect",
                    detail: "{\"event\":\"post_refresh_soft_reconnect\"}"
                ))
                self.session?.requestLinkReconnect(reason: "post_refresh_sub_timeout")
                self.keepAlive.nudgeLocationSubscription()
            } else {
                self.session?.triggerFastBurst(seconds: 15.0)
                self.keepAlive.nudgeLocationSubscription()
            }

            // 12.0s: if STILL unconfirmed (common on >100 km jumps or when Control Center Wi-Fi is still on),
            // unlock immediate in-place retry with a deeper 25–30s countdown right inside Settings!
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning, self.isLocationRefreshGuideActive else { return }
            if self.isAccessoryLocationConfirmed { return }
            self.locationRefreshRetryCount += 1
            self.locationRefreshSawDisabled = false
            self.needsLocationServiceRefresh = true
            let nextSecs = min(30, max(self.effectiveRefreshCountdownSeconds, 25))
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 1,
                headline: L10n.tr("pip.step3.retry_longer.headline"),
                subtitle: L10n.format("pip.step3.retry_longer.subtitle", nextSecs)
            )
        }
    }

    /// Manually triggers a zero-click iAP2 soft-reconnect + fast NMEA burst without leaving Reloc.
    public func retryAutoLock() {
        guard snapshot.isRunning else { return }
        needsLocationServiceRefresh = false
        lastAutoReconnectAt = ProcessInfo.processInfo.systemUptime
        session?.triggerFastBurst(seconds: 15.0)
        if snapshot.activeSentences.isEmpty {
            keepAlive.pulseLocationSubscription()
            handleSessionAuthenticated()
        } else {
            session?.requestLinkReconnect(reason: "manual_retry_soft_reconnect")
            keepAlive.nudgeLocationSubscription()
            scheduleLockWatchdog()
        }
    }

    private func startLocationRefreshCountdown() {
        refreshCountdownTask?.cancel()
        postRefreshRecoveryTask?.cancel()
        postRefreshRecoveryTask = nil
        keepAlive.beginTransientBackgroundBridge(reason: "Reloc.LocationRefreshCountdown")
        let baseCountdown = effectiveRefreshCountdownSeconds
        let rawCountdown = locationRefreshRetryCount > 0 ? max(baseCountdown, 25) : baseCountdown
        let countdownTotal = max(5, min(30, rawCountdown))
        refreshCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: countdownTotal, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.isLocationRefreshGuideActive else { return }
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 2,
                    headline: L10n.tr("pip.step2.headline"),
                    subtitle: L10n.tr("pip.step2.subtitle"),
                    countdown: remaining
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self, self.isLocationRefreshGuideActive else { return }
            RelocTheme.hapticMedium()
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: L10n.tr("pip.step3.enable.headline"),
                subtitle: L10n.tr("pip.step3.enable.subtitle"),
                countdown: 0
            )
        }
    }

    public func openLocationServicesSettings() {
        let candidates = [
            "App-Prefs:root=Privacy&path=LOCATION",
            "prefs:root=Privacy&path=LOCATION",
            UIApplication.openSettingsURLString,
        ]
        openFirstSupportedURL(candidates)
    }

    public func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func openFirstSupportedURL(_ strings: [String], index: Int = 0) {
        guard index < strings.count, let url = URL(string: strings[index]) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            if !success {
                Task { @MainActor in
                    self?.openFirstSupportedURL(strings, index: index + 1)
                }
            }
        }
    }

    // MARK: - Places Management

    public var favoriteGroups: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for fav in favorites {
            if let grp = fav.group?.trimmingCharacters(in: .whitespacesAndNewlines), !grp.isEmpty, seen.insert(grp).inserted {
                result.append(grp)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func toggleFavoriteForInspected() {
        let loc = inspectedLocation
        if let idx = favorites.firstIndex(where: { abs($0.latitude - loc.latitude) < 1e-4 && abs($0.longitude - loc.longitude) < 1e-4 }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(
                FavoriteLocation(
                    name: selectedPlaceName,
                    subtitle: selectedPlaceAddress,
                    latitude: loc.latitude,
                    longitude: loc.longitude,
                    altitude: loc.altitude
                ),
                at: 0
            )
        }
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func toggleFavorite(forRecent recent: RecentLocation) {
        if let idx = favorites.firstIndex(where: { abs($0.latitude - recent.latitude) < 1e-4 && abs($0.longitude - recent.longitude) < 1e-4 }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(
                FavoriteLocation(
                    name: recent.name,
                    subtitle: recent.subtitle,
                    latitude: recent.latitude,
                    longitude: recent.longitude,
                    altitude: recent.altitude
                ),
                at: 0
            )
        }
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func saveCurrentAsFavorite(name: String, group: String? = nil, note: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let loc = inspectedLocation
        favorites.insert(
            FavoriteLocation(
                name: trimmed,
                subtitle: selectedPlaceAddress,
                group: group,
                note: note,
                latitude: loc.latitude,
                longitude: loc.longitude,
                altitude: loc.altitude
            ),
            at: 0
        )
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func updateFavorite(
        id: UUID,
        name: String,
        subtitle: String?,
        group: String?,
        note: String?,
        latitude: Double,
        longitude: Double,
        altitude: Double
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              latitude.isFinite, longitude.isFinite, altitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude),
              let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[idx] = FavoriteLocation(
            id: id,
            name: trimmed,
            subtitle: (cleanSubtitle?.isEmpty == false) ? cleanSubtitle : nil,
            group: (cleanGroup?.isEmpty == false) ? cleanGroup : nil,
            note: (cleanNote?.isEmpty == false) ? cleanNote : nil,
            latitude: latitude,
            longitude: longitude,
            altitude: min(50_000.0, max(-500.0, altitude))
        )
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func renameFavorite(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[idx].name = trimmed
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func deleteFavorite(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func deleteFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        store.saveFavorites(favorites)
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    public func recordRecent(name: String, subtitle: String?, location: TargetLocation) {
        recents.removeAll {
            abs($0.latitude - location.latitude) < 1e-4 && abs($0.longitude - location.longitude) < 1e-4
        }
        recents.insert(
            RecentLocation(
                name: name.isEmpty ? String(format: "%.5f, %.5f", location.latitude, location.longitude) : name,
                subtitle: subtitle,
                latitude: location.latitude,
                longitude: location.longitude,
                altitude: location.altitude
            ),
            at: 0
        )
        if recents.count > 30 {
            recents = Array(recents.prefix(30))
        }
        store.saveRecents(recents)
    }

    public func deleteRecent(id: UUID) {
        recents.removeAll { $0.id == id }
        store.saveRecents(recents)
    }

    public func clearRecents() {
        recents.removeAll()
        store.saveRecents([])
    }

    public func clearLogs() {
        events.removeAll()
    }

    public func exportedLogsText() -> String {
        let formatter = ISO8601DateFormatter()
        return events.map { "[\(formatter.string(from: $0.timestamp))] \($0.detail)" }.joined(separator: "\n")
    }

    // MARK: - Shortcuts (App Intents) & URL Scheme Helpers

    public var isMFiSignerReady: Bool {
        mfiSigner != nil
    }

    /// Tears down an active session cleanly without launching real-GPS recovery so a Shortcut
    /// can immediately switch from a route/joystick session to a fixed favorite or another route.
    private func stopSessionForImmediateSwitch() async {
        guard snapshot.isRunning else { return }
        cancelTriggerTasks()
        let activeSession = session
        session = nil
        pendingBackgroundSnapshot = nil
        pendingBackgroundTrajectoryProgress = nil
        pendingBackgroundJoystickProgress = nil
        isRouteSessionActive = false
        trajectoryProgress = nil
        isJoystickSessionActive = false
        joystickProgress = nil
        joystickCruiseLocked = false
        activeSession?.stop()
        keepAlive.stop()
        coreLocation.setExternalFeedActive(false)
        snapshot.isRunning = false
        snapshot.activeSentences = []
        isAccessoryLocationConfirmed = false
        consecutiveLockLossCount = 0
        resetDeadReckoningTracker()
        needsLocationServiceRefresh = false
        injectionPhase = .idle
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Starts fixed-pin location injection (or live-updates coordinates if fixed mode is already active).
    public func startFixedLocationFromShortcut(
        wgsLocation: TargetLocation,
        name: String?,
        subtitle: String? = nil,
        resolveAltitude: Bool = false
    ) async {
        let displayName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
        let displaySubtitle = (subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)

        if snapshot.isRunning && !isRouteSessionActive && !isJoystickSessionActive {
            selectedPlaceName = displayName
            selectedPlaceAddress = displaySubtitle
            pendingLocation = wgsLocation
            applyPendingLocationUpdate()
            if resolveAltitude {
                resolveElevation(for: wgsLocation)
            }
            return
        }

        if snapshot.isRunning {
            await stopSessionForImmediateSwitch()
        }

        controlMode = .fixed
        pendingLocation = nil
        targetLocation = wgsLocation
        selectedPlaceName = displayName
        selectedPlaceAddress = displaySubtitle
        if resolveAltitude {
            resolveElevation(for: wgsLocation)
        }
        pendingCameraFocus = activeMapCoordinate
        start(mode: .send)
    }

    /// Loads and starts a saved route by ID or name (used by App Intents and `reloc://route`).
    @discardableResult
    public func startSavedRouteFromShortcut(
        routeID: String? = nil,
        routeName: String? = nil,
        speedOverrideMps: Double? = nil
    ) async -> Bool {
        let match: SavedRoute? = {
            if let idStr = routeID, let uuid = UUID(uuidString: idStr),
               let found = savedRoutes.first(where: { $0.id == uuid }) {
                return found
            }
            if let name = routeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if let exact = savedRoutes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    return exact
                }
                if let partial = savedRoutes.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    return partial
                }
            }
            return nil
        }()
        guard let route = match else { return false }

        if snapshot.isRunning {
            await stopSessionForImmediateSwitch()
        }
        loadSavedRoute(route)
        if let overrideSpeed = speedOverrideMps, overrideSpeed.isFinite, overrideSpeed >= 0.3 {
            routeSpeedMps = min(35.0, overrideSpeed)
        }
        if let first = routeMapWaypointCoordinates.first {
            pendingCameraFocus = first
        }
        startRouteSession()
        return isRouteSessionActive
    }

    /// Waits briefly until iAP2 MFi authentication finishes (or session errors/stops) before
    /// launching the Location Services cache-refresh transition.
    public func waitForShortcutAuthReady(timeoutSeconds: TimeInterval = 2.5) async {
        let deadline = Date().addingTimeInterval(max(0.2, timeoutSeconds))
        while Date() < deadline {
            if !snapshot.isRunning || snapshot.lastError != nil || snapshot.authenticated {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Handles incoming `.gpx` / `.json` backup files (from Files / AirDrop / "Open in Reloc") as well as
    /// `reloc://` URL commands:
    /// - `reloc://start?lat=...&lon=...&alt=...&name=...&gcj02=0|1&refresh=0|1`
    /// - `reloc://route?id=...&name=...&speed=...&refresh=0|1`
    /// - `reloc://favorite?id=...&name=...&refresh=0|1`
    /// - `reloc://stop?refresh=0|1`
    /// - `reloc://refresh`
    public func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            Task { @MainActor [weak self] in
                self?.importDataFile(from: url)
            }
            return
        }
        guard url.scheme?.lowercased() == "reloc" else { return }
        let action = (url.host ?? "").lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        func param(_ key: String) -> String? {
            queryItems.first(where: { $0.name.lowercased() == key })?.value
        }
        let autoRefresh = (param("refresh")?.lowercased() ?? "1") != "0"

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch action {
            case "stop":
                if self.snapshot.isRunning {
                    self.stopAndRestore()
                }
                if param("refresh")?.lowercased() == "1" {
                    self.launchOneTapRestoreRefresh()
                }
            case "refresh":
                if self.snapshot.isRunning {
                    self.launchOneTapLocationRefresh()
                } else {
                    self.launchOneTapRestoreRefresh()
                }
            case "start":
                guard let latStr = param("lat"), let lonStr = param("lon"),
                      let rawLat = Double(latStr), let rawLon = Double(lonStr),
                      rawLat.isFinite, rawLon.isFinite,
                      (-90.0...90.0).contains(rawLat),
                      (-180.0...180.0).contains(rawLon) else {
                    self.alertMessage = L10n.tr("intent.error.invalid_coordinate")
                    return
                }
                let isGCJ02 = (param("gcj02")?.lowercased() == "1" || param("gcj02")?.lowercased() == "true")
                let wgs: CLLocationCoordinate2D = isGCJ02
                    ? CoordinateTransform.gcj02ToWGS84(lat: rawLat, lon: rawLon)
                    : CLLocationCoordinate2D(latitude: rawLat, longitude: rawLon)
                let parsedAlt = param("alt").flatMap(Double.init).flatMap { $0.isFinite ? min(50_000.0, max(-500.0, $0)) : nil }
                let loc = TargetLocation(
                    latitude: wgs.latitude,
                    longitude: wgs.longitude,
                    altitude: parsedAlt ?? self.inspectedLocation.altitude
                )
                await self.startFixedLocationFromShortcut(
                    wgsLocation: loc,
                    name: param("name"),
                    subtitle: nil,
                    resolveAltitude: parsedAlt == nil
                )
                if autoRefresh {
                    await self.waitForShortcutAuthReady(timeoutSeconds: 2.5)
                    if self.snapshot.isRunning {
                        self.launchOneTapLocationRefresh()
                    }
                }
            case "route":
                let speedOverride = param("speed").flatMap(Double.init)
                let started = await self.startSavedRouteFromShortcut(
                    routeID: param("id"),
                    routeName: param("name"),
                    speedOverrideMps: speedOverride
                )
                if !started {
                    self.alertMessage = L10n.tr("intent.error.route_not_found")
                    return
                }
                if autoRefresh {
                    await self.waitForShortcutAuthReady(timeoutSeconds: 2.5)
                    if self.snapshot.isRunning {
                        self.launchOneTapLocationRefresh()
                    }
                }
            case "favorite":
                let fav: FavoriteLocation? = {
                    if let idStr = param("id"), let uuid = UUID(uuidString: idStr) {
                        return self.favorites.first(where: { $0.id == uuid })
                    }
                    if let name = param("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                        return self.favorites.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
                    }
                    return self.favorites.first
                }()
                if let fav {
                    await self.startFixedLocationFromShortcut(
                        wgsLocation: TargetLocation(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                        name: fav.name,
                        subtitle: fav.subtitle
                    )
                    if autoRefresh {
                        await self.waitForShortcutAuthReady(timeoutSeconds: 2.5)
                        if self.snapshot.isRunning {
                            self.launchOneTapLocationRefresh()
                        }
                    }
                }
            default:
                break
            }
        }
    }
}
