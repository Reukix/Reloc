import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

public enum InjectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case waitingSubscription
    case injectingPendingLock
    case activeConfirmed
}

struct BackgroundRefreshReport: Codable {
    enum State: String, Codable {
        case locationConfirmed
        case awaitingLocation
        case recoveryAvailable

        var title: String {
            switch self {
            case .locationConfirmed: return "定位会话已确认"
            case .awaitingLocation: return "等待系统确认定位"
            case .recoveryAvailable: return "已保留位置，可手动恢复"
            }
        }
    }

    let date: Date
    let state: State
}

@MainActor
public final class RelocViewModel: ObservableObject {
    static let backgroundRefreshTaskIdentifier = "dev.reloc.ios.session-refresh"

    public let store = CredentialStore()
    public let coreLocation = LiveCoreLocationMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let geocoder = CLGeocoder()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Loopback & Connection Settings
    @Published public var host: String {
        didSet {
            store.host = host
            invalidateDeviceConnection()
        }
    }
    @Published public var remotePort: UInt16 {
        didSet {
            store.remotePort = remotePort
            invalidateDeviceConnection()
        }
    }
    @Published public var lockdownPort: UInt16 {
        didSet {
            store.lockdownPort = lockdownPort
            invalidateDeviceConnection()
        }
    }
    @Published public var serviceName: String {
        didSet { store.serviceName = serviceName }
    }
    @Published public var intervalSeconds: Double {
        didSet { store.intervalSeconds = intervalSeconds }
    }
    @Published public var durationSeconds: Double {
        didSet { store.durationSeconds = durationSeconds }
    }
    @Published public var gcj02CorrectionEnabled: Bool {
        didSet { store.gcj02CorrectionEnabled = gcj02CorrectionEnabled }
    }
    @Published public var backgroundKeepAliveEnabled: Bool {
        didSet {
            store.backgroundKeepAliveEnabled = backgroundKeepAliveEnabled
            keepAlive.setAudioKeepAliveEnabled(backgroundKeepAliveEnabled)
        }
    }
    @Published var backgroundRefreshEnabled: Bool {
        didSet {
            store.backgroundRefreshEnabled = backgroundRefreshEnabled
            updateBackgroundRefreshSchedule()
        }
    }
    @Published private(set) var systemBackgroundRefreshStatus: UIBackgroundRefreshStatus = .denied
    @Published private(set) var backgroundRefreshReport: BackgroundRefreshReport?
    @Published private(set) var backgroundRefreshScheduleError: String?
    @Published public var microJitterEnabled: Bool {
        didSet {
            store.microJitterEnabled = microJitterEnabled
            if snapshot.isRunning {
                if microJitterEnabled {
                    startJitterTimer()
                } else {
                    stopJitterTimer()
                    pushLocationToSession()
                }
            }
        }
    }
    @Published public var appearanceMode: AppAppearanceMode {
        didSet { store.appearanceMode = appearanceMode }
    }
    @Published public var mapStyle: MapDisplayStyle {
        didSet { store.mapStyle = mapStyle }
    }
    @Published public var mapSource: MapSource {
        didSet { store.mapSource = mapSource }
    }

    // MARK: - Target & Selected Location (WGS-84)
    /// The location currently being sent to the iPhone (or ready to send).
    @Published public var targetLocation: TargetLocation {
        didSet {
            store.lastTargetLocation = targetLocation
            pushLocationToSession()
        }
    }
    /// Candidate pin dropped on the map while a session is already active (allows browsing before tapping "更新到此位置").
    @Published public var pendingLocation: TargetLocation?
    @Published public var selectedPlaceName: String = "选中位置"
    @Published public var selectedPlaceAddress: String = ""

    // MARK: - Favorites, Recents (30), & Recovery
    @Published public var favorites: [FavoriteLocation] = []
    @Published public var recents: [RecentLocation] = []
    @Published public var interruptedSession: InterruptedSessionRecord?

    // MARK: - Device Pairing & Verification State
    @Published public var pairingStatus: PairingStatus
    @Published public var deviceUDID: String
    @Published public var connectionVerified = false
    @Published public var isVerifyingConnection = false
    @Published public var connectionCheckFailed = false
    @Published public var deviceConnectionStatus = "请先配对这台 iPhone"
    @Published public var discoveredDevicePort: UInt16?

    // MARK: - Session & Diagnostics
    @Published public var snapshot = SessionSnapshot()
    @Published public var injectionPhase: InjectionPhase = .idle
    @Published public var isAccessoryLocationConfirmed = false
    @Published public var needsLocationServiceRefresh = false
    @Published public var isLocationRefreshGuideActive = false
    @Published public var isRestoringRealLocation = false
    @Published public var needsRestoreLocationRefresh = false
    @Published public var realLocationRestoredNotice = false
    @Published public var events: [ProtocolEvent] = []
    @Published public var alertMessage: String?

    private var savedPairing: SavedPairing?
    private var mfiSigner: RLMFiSigner?
    private var session: AccessoryLocationSession?
    private var jitterTimer: Timer?
    private var subscriptionPulseTask: Task<Void, Never>?
    private var lockWatchdogTask: Task<Void, Never>?
    private var refreshCountdownTask: Task<Void, Never>?
    private var locationStopDebounceTask: Task<Void, Never>?
    private var locationRefreshSawDisabled = false
    private var restoreTask: Task<Void, Never>?
    private var isRestoreRefreshGuideActive = false
    private var lastRestoreAuthStatus: CLAuthorizationStatus = .notDetermined
    private var geocodeTask: Task<Void, Never>?
    private var geocodeGeneration: Int = 0
    private var hasEnteredForeground = false

    public init() {
        self.host = store.host
        self.remotePort = store.remotePort
        self.lockdownPort = store.lockdownPort
        self.serviceName = store.serviceName
        self.intervalSeconds = store.intervalSeconds
        self.durationSeconds = store.durationSeconds
        self.gcj02CorrectionEnabled = store.gcj02CorrectionEnabled
        self.backgroundKeepAliveEnabled = store.backgroundKeepAliveEnabled
        self.backgroundRefreshEnabled = store.backgroundRefreshEnabled
        self.backgroundRefreshReport = store.backgroundRefreshReport
        self.microJitterEnabled = store.microJitterEnabled
        self.appearanceMode = store.appearanceMode
        self.mapStyle = store.mapStyle
        self.mapSource = store.mapSource
        self.targetLocation = store.lastTargetLocation
        self.favorites = store.loadFavorites()
        self.recents = store.loadRecents()
        self.interruptedSession = store.loadInterruptedSession()
        self.deviceUDID = store.deviceUDID

        self.mfiSigner = store.loadBundledMFiSigner()

        let (pairing, pairStat) = store.loadPairing()
        self.savedPairing = pairing
        self.pairingStatus = pairStat
        self.deviceConnectionStatus = UIDevice.current.userInterfaceIdiom == .pad
            ? "不支持 iPad（仅支持 iPhone）"
            : (pairStat.isLoaded ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone")

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

        self.coreLocation.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] telemetry in
                self?.evaluateCoreLocationConfirmation(telemetry)
            }
            .store(in: &cancellables)

        self.coreLocation.$authorizationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.handleCoreLocationAuthChangeForRestore(status)
            }
            .store(in: &cancellables)
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

    /// Converts an `MKLocalSearch` result coordinate into canonical WGS-84.
    /// Apple's `MKLocalSearch` returns GCJ-02 for Mainland China POIs regardless of custom tile overlays.
    public func selectSearchResultCoordinate(_ searchCoord: CLLocationCoordinate2D, name: String? = nil, address: String? = nil) {
        let wgs: CLLocationCoordinate2D
        if gcj02CorrectionEnabled && !CoordinateTransform.isOutsideChina(lat: searchCoord.latitude, lon: searchCoord.longitude) {
            wgs = CoordinateTransform.gcj02ToWGS84(lat: searchCoord.latitude, lon: searchCoord.longitude)
        } else {
            wgs = searchCoord
        }
        selectWGSLocation(
            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: name,
            address: address
        )
    }

    public var activeMapCoordinate: CLLocationCoordinate2D {
        toMapCoordinate(CLLocationCoordinate2D(latitude: targetLocation.latitude, longitude: targetLocation.longitude))
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
            address: address
        )
    }

    public func selectWGSLocation(_ wgsLoc: TargetLocation, name: String? = nil, address: String? = nil) {
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
            selectedPlaceAddress = "正在解析地名…"
            reverseGeocode(wgsLocation: wgsLoc)
        }
    }

    public func clearPendingSelection() {
        pendingLocation = nil
        reverseGeocode(wgsLocation: targetLocation)
    }

    public func applyPendingLocationUpdate() {
        guard let pending = pendingLocation else { return }
        targetLocation = pending
        pendingLocation = nil
        isAccessoryLocationConfirmed = false
        session?.markCoreLocationConfirmed(false)
        session?.triggerFastBurst(seconds: 8.0)
        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        if snapshot.isRunning {
            updateInjectionPhase()
            scheduleLockWatchdog()
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

            // 4. Final fallback: never leave "正在解析地名…" stuck on screen.
            self.selectedPlaceName = coordText
            self.selectedPlaceAddress = "WGS-84 坐标"
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

            geocoder.reverseGeocodeLocation(clLoc) { placemarks, _ in
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
        guard let url = URL(string: "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=\(latStr)&lon=\(lonStr)&zoom=18&addressdetails=1&accept-language=zh-CN,en") else {
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
        guard let url = URL(string: "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=\(latStr)&longitude=\(lonStr)&localityLanguage=zh") else {
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

    // MARK: - Optional Stationary Micro-Jitter

    private func startJitterTimer() {
        stopJitterTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.microJitterEnabled, self.snapshot.isRunning else { return }
                self.pushLocationToSession()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        jitterTimer = timer
    }

    private func stopJitterTimer() {
        jitterTimer?.invalidate()
        jitterTimer = nil
    }

    private func pushLocationToSession() {
        let outgoing = microJitterEnabled
            ? CoordinateTransform.applyMicroJitter(to: targetLocation)
            : targetLocation
        session?.locationBox.set(outgoing)
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
        clearBackgroundRefreshReport()
        cancelBackgroundRefresh()
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

    // MARK: - Background App Refresh

    func appDidBecomeActive() {
        backgroundRefreshPolicyDidChange()
        if !hasEnteredForeground {
            hasEnteredForeground = true
            reverseGeocode(wgsLocation: targetLocation)
        }
    }

    func appDidEnterBackground() {
        // A cold launch to deliver a refresh task should not queue another one.
        guard hasEnteredForeground else { return }
        updateBackgroundRefreshSchedule()
    }

    func backgroundRefreshPolicyDidChange() {
        systemBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        if systemBackgroundRefreshStatus != .available {
            cancelBackgroundRefresh()
        }
    }

    func updateBackgroundRefreshSchedule(earliestBeginDate: Date? = nil) {
        systemBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        guard backgroundRefreshEnabled, !isUnsupportedIPad,
              systemBackgroundRefreshStatus == .available,
              store.loadInterruptedSession() != nil else {
            cancelBackgroundRefresh()
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundRefreshScheduleError = nil
        } catch {
            backgroundRefreshScheduleError = error.localizedDescription
        }
    }

    private func cancelBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskIdentifier)
        backgroundRefreshScheduleError = nil
    }

    private func clearBackgroundRefreshReport() {
        store.backgroundRefreshReport = nil
        backgroundRefreshReport = nil
    }

    func performBackgroundRefresh() {
        guard !Task.isCancelled, backgroundRefreshEnabled, !isUnsupportedIPad,
              UIApplication.shared.backgroundRefreshStatus == .available,
              store.loadInterruptedSession() != nil else { return }

        let now = Date()
        let state: BackgroundRefreshReport.State
        if snapshot.isRunning {
            let hasRecentLocation = coreLocation.latest.map { abs($0.timestamp.timeIntervalSince(now)) < 15 } ?? false
            state = snapshot.authenticated && isAccessoryLocationConfirmed && hasRecentLocation
                ? .locationConfirmed : .awaitingLocation
        } else {
            state = .recoveryAvailable
        }

        let report = BackgroundRefreshReport(date: now, state: state)
        store.backgroundRefreshReport = report
        backgroundRefreshReport = report

        if snapshot.isRunning {
            updateBackgroundRefreshSchedule(earliestBeginDate: report.date.addingTimeInterval(15 * 60))
        }
    }

    // MARK: - Device Compatibility

    public var isUnsupportedIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    public static let unsupportedIPadMessage =
        "当前设备为 iPad。由于 iPadOS 不提供 CarPlay / CarKit（com.apple.carkit.service）外设定位服务，Reloc 仅支持 iPhone 使用。"

    // MARK: - Device Pairing & Loopback Verification

    public var canStartSession: Bool {
        !isUnsupportedIPad && savedPairing != nil && mfiSigner != nil && !snapshot.isRunning
    }

    public func invalidateDeviceConnection() {
        connectionVerified = false
        discoveredDevicePort = nil
        connectionCheckFailed = false
        deviceConnectionStatus = pairingStatus.isLoaded ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone"
    }

    public func startDevicePairing() {
        if isUnsupportedIPad {
            alertMessage = Self.unsupportedIPadMessage
            return
        }
        guard !snapshot.isRunning, !isVerifyingConnection else { return }
        DevicePairingCoordinator.shared.start { [weak self] rawRecord, hostIRK, udid in
            guard let self else { return }
            _ = try self.store.saveOnDevicePairedIdentity(rawRecord, hostIRK: hostIRK, udid: udid)
            self.reloadPairing()
            self.invalidateDeviceConnection()
            self.testConnection(silent: true)
        }
    }

    public func importDiscoveredPairing() {
        guard !snapshot.isRunning, !DevicePairingCoordinator.shared.isRunning else { return }
        if store.importDiscoveredPairingInDocuments() != nil {
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(name: "pairing_auto_imported", detail: "{\"event\":\"pairing_auto_imported\"}"))
        }
    }

    public func verifyConnectionIfNeeded() async {
        guard pairingStatus.isLoaded,
              !connectionVerified,
              !isVerifyingConnection,
              !snapshot.isRunning,
              !DevicePairingCoordinator.shared.isRunning else {
            return
        }
        testConnection(silent: true)
    }

    public func testConnection(silent: Bool = false) {
        if isUnsupportedIPad {
            deviceConnectionStatus = "不支持 iPad（仅支持 iPhone）"
            if !silent {
                alertMessage = Self.unsupportedIPadMessage
            }
            return
        }
        guard !isVerifyingConnection, !snapshot.isRunning else { return }
        guard let pairing = savedPairing else {
            deviceConnectionStatus = "请先配对这台 iPhone 或导入配对文件"
            return
        }

        let currentHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRemotePort = remotePort
        let currentLockdownPort = lockdownPort

        isVerifyingConnection = true
        connectionVerified = false
        connectionCheckFailed = false
        deviceConnectionStatus = "正在发现服务并验证配对身份…"

        Task {
            defer { isVerifyingConnection = false }
            do {
                let result = try await AccessoryLocationSession.verifyConnection(
                    host: currentHost,
                    remotePort: currentRemotePort,
                    lockdownPort: currentLockdownPort,
                    pairing: pairing
                )
                guard self.host.trimmingCharacters(in: .whitespacesAndNewlines) == currentHost,
                      self.remotePort == currentRemotePort,
                      self.lockdownPort == currentLockdownPort else {
                    self.invalidateDeviceConnection()
                    return
                }
                if !result.udid.isEmpty {
                    self.deviceUDID = result.udid
                    self.store.deviceUDID = result.udid
                }
                self.discoveredDevicePort = result.port
                self.connectionVerified = true
                self.deviceConnectionStatus = "设备身份与回环连接已验证"
                self.events.append(ProtocolEvent(
                    name: "connection_verified",
                    detail: "{\"event\":\"connection_verified\",\"port\":\(result.port),\"service\":\"\(result.carkitService ?? "lockdown")\"}"
                ))
            } catch {
                self.connectionVerified = false
                self.connectionCheckFailed = true
                self.deviceConnectionStatus = error.localizedDescription
                self.events.append(ProtocolEvent(
                    name: "connection_check_failed",
                    detail: "{\"event\":\"connection_check_failed\",\"detail\":\"\(error.localizedDescription)\"}",
                    isError: true
                ))
                if !silent {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Location Injection Session

    public func start(mode: SessionMode) {
        if isUnsupportedIPad {
            alertMessage = Self.unsupportedIPadMessage
            return
        }
        guard !snapshot.isRunning else { return }
        guard let pairing = savedPairing else {
            alertMessage = "请先在「设备连接」页面完成本机配对或导入配对文件，并确保外部代理已启用 10.7.0.1 回环映射。"
            return
        }
        guard let mfiSigner else {
            alertMessage = "内置配件认证组件不可用，请重新安装应用。"
            return
        }

        if let pending = pendingLocation {
            targetLocation = pending
            pendingLocation = nil
        }

        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        interruptedSession = nil
        clearBackgroundRefreshReport()
        if microJitterEnabled {
            startJitterTimer()
        }

        let config = SessionConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePort: remotePort,
            lockdownPort: lockdownPort,
            serviceName: serviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            intervalSeconds: intervalSeconds,
            durationSeconds: mode == .probe ? max(20.0, durationSeconds) : durationSeconds
        )

        isAccessoryLocationConfirmed = false
        needsLocationServiceRefresh = false
        isLocationRefreshGuideActive = false
        cancelRestoreRecovery()
        injectionPhase = .connecting
        cancelTriggerTasks()

        // Defer location updates until authentication completes so we don't wake internal GPS early
        // and poison `locationd`'s fusion cache with a fresh real location.
        keepAlive.prepareForSession(useSilentAudio: backgroundKeepAliveEnabled)

        let newSession = AccessoryLocationSession(
            initialLocation: targetLocation,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.events.append(event)
                    if self.events.count > 500 {
                        self.events.removeFirst(self.events.count - 500)
                    }
                }
            },
            onSnapshot: { [weak self] snap in
                Task { @MainActor in
                    guard let self else { return }
                    self.snapshot = snap
                    self.updateInjectionPhase()
                    if !snap.isRunning {
                        self.cancelTriggerTasks()
                        self.stopJitterTimer()
                        self.keepAlive.stop()
                        self.cancelBackgroundRefresh()
                        self.interruptedSession = self.store.loadInterruptedSession()
                        if !self.isRestoringRealLocation {
                            self.coreLocation.stop()
                        }
                        self.isAccessoryLocationConfirmed = false
                        self.needsLocationServiceRefresh = false
                        self.injectionPhase = .idle
                        if self.isLocationRefreshGuideActive {
                            self.isLocationRefreshGuideActive = false
                            PairingPiPPresenter.shared.finishLocationRefresh(succeeded: false, message: "定位会话已停止")
                        }
                    }
                }
            },
            onAuthenticated: { [weak self] in
                Task { @MainActor in
                    self?.handleSessionAuthenticated()
                }
            },
            onLocationRequested: { [weak self] in
                Task { @MainActor in
                    self?.handleLocationSubscribed()
                }
            },
            onLocationStopped: { [weak self] in
                Task { @MainActor in
                    self?.handleLocationStoppedBySystem()
                }
            },
            onSubscriptionRestarted: { [weak self] in
                Task { @MainActor in
                    self?.keepAlive.refreshAfterLocationToggle()
                }
            }
        )
        self.session = newSession
        newSession.start(
            configuration: config,
            pairing: pairing,
            discoveredRemotePort: discoveredDevicePort,
            mfiSigner: mfiSigner
        )
        updateBackgroundRefreshSchedule()
    }

    public func stopAndRestore() {
        cancelTriggerTasks()
        stopJitterTimer()
        session?.stop()
        keepAlive.stop()
        isAccessoryLocationConfirmed = false
        needsLocationServiceRefresh = false
        injectionPhase = .idle
        if isLocationRefreshGuideActive {
            isLocationRefreshGuideActive = false
            PairingPiPPresenter.shared.teardown()
        }
        dismissInterruptedSession()
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
            PairingPiPPresenter.shared.teardown()
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
            self.coreLocation.pulseForAccessoryLock()
            self.events.append(ProtocolEvent(
                name: "real_location_recovery_started",
                detail: "{\"event\":\"real_location_recovery_started\"}"
            ))

            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            self.coreLocation.pulseForAccessoryLock()

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
                PairingPiPPresenter.shared.updateLocationRefresh(
                    step: 3,
                    headline: "③ 系统已重新打开定位服务",
                    subtitle: "正在极速锁定外设 GPS，请稍候 1–2 秒…"
                )
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
            PairingPiPPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: "③ 正在重新获取本机真实定位…",
                subtitle: "已重新打开定位服务，请稍候 1–2 秒"
            )
            coreLocation.requestAndStart()
            coreLocation.pulseForAccessoryLock()
        }
    }

    public func launchOneTapRestoreRefresh() {
        restoreTask?.cancel()
        restoreTask = nil
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        isRestoreRefreshGuideActive = true
        isRestoringRealLocation = true
        lastRestoreAuthStatus = coreLocation.authorizationStatus
        PairingPiPPresenter.shared.startLocationRefreshGuide()
        PairingPiPPresenter.shared.updateLocationRefresh(
            step: 1,
            headline: "① 关闭系统「定位服务」",
            subtitle: "清空外设残留缓存，关闭后自动开始 5 秒倒计时"
        )
        // Let PiP enter smoothly before switching apps to Settings (avoids transition stutter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isRestoreRefreshGuideActive else { return }
            self.openLocationServicesSettings()
        }
    }

    private func startRestoreRefreshCountdown() {
        refreshCountdownTask?.cancel()
        refreshCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 5, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.isRestoreRefreshGuideActive else { return }
                PairingPiPPresenter.shared.updateLocationRefresh(
                    step: 2,
                    headline: "② 正在清空外设残留缓存",
                    subtitle: "请保持「定位服务」关闭，等待倒计时结束",
                    countdown: remaining
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self, self.isRestoreRefreshGuideActive else { return }
            RelocTheme.hapticMedium()
            PairingPiPPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: "③ 请重新打开「定位服务」",
                subtitle: "打开开关后将立即切回本机真实 GPS",
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
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        locationStopDebounceTask?.cancel()
        locationStopDebounceTask = nil
        locationRefreshSawDisabled = false
    }

    private func handleSessionAuthenticated() {
        guard snapshot.isRunning else { return }
        // Activate navigation-grade CoreLocation right AFTER iAP2 auth succeeds so `locationd`
        // immediately pairs this fresh request with our authenticated external MFi GPS accessory.
        keepAlive.activateLocationSubscription(forceRestart: true)
        coreLocation.requestAndStart()
        updateInjectionPhase()

        // If `locationd` doesn't dispatch 0xFFFA within 1.5s, pulse CoreLocation automatically up to 3 times.
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = Task { @MainActor [weak self] in
            for attempt in 1...3 {
                let delayNs: UInt64 = attempt == 1 ? 1_500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
                if !self.snapshot.activeSentences.isEmpty { return }
                self.events.append(ProtocolEvent(
                    name: "auto_subscription_pulse",
                    detail: "{\"event\":\"auto_subscription_pulse\",\"attempt\":\(attempt)}"
                ))
                self.keepAlive.pulseLocationSubscription()
                self.coreLocation.pulseForAccessoryLock()
            }
        }
    }

    private func handleLocationSubscribed() {
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = nil
        locationStopDebounceTask?.cancel()
        locationStopDebounceTask = nil
        updateInjectionPhase()

        if isLocationRefreshGuideActive {
            if locationRefreshSawDisabled {
                refreshCountdownTask?.cancel()
                refreshCountdownTask = nil
                PairingPiPPresenter.shared.updateLocationRefresh(
                    step: 3,
                    headline: "③ 系统已重新订阅外设 GPS",
                    subtitle: "正在极速锁定目标坐标，请稍候 1–2 秒…"
                )
            }
            // Do not schedule CoreLocation pulses while the PiP refresh guide is active.
            return
        }
        scheduleLockWatchdog()
    }

    private func handleLocationStoppedBySystem() {
        isAccessoryLocationConfirmed = false
        session?.markCoreLocationConfirmed(false)
        updateInjectionPhase()

        // Debounce 0xFFFC by 0.9s so transient app-switch hiccups never falsely flash "5 秒"
        // when the user hasn't actually turned off Location Services yet.
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
        }
    }

    private func scheduleLockWatchdog() {
        lockWatchdogTask?.cancel()
        lockWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                // Silent automatic nudge before asking user to touch anything.
                self.events.append(ProtocolEvent(
                    name: "auto_lock_nudge",
                    detail: "{\"event\":\"auto_lock_nudge\"}"
                ))
                self.session?.triggerFastBurst(seconds: 10.0)
                self.keepAlive.pulseLocationSubscription()
                self.coreLocation.pulseForAccessoryLock()
            }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                self.needsLocationServiceRefresh = true
            }
        }
    }

    private func evaluateCoreLocationConfirmation(_ telemetry: LiveLocationTelemetry?) {
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
                    PairingPiPPresenter.shared.finishLocationRefresh(
                        succeeded: true,
                        message: "已切回本机真实 GPS，可返回任意 App 使用",
                        headline: "本机真实定位已恢复"
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
            }
            return
        }
        let targetCL = CLLocation(latitude: targetLocation.latitude, longitude: targetLocation.longitude)
        let reportedCL = CLLocation(latitude: telemetry.latitude, longitude: telemetry.longitude)
        let distance = targetCL.distance(from: reportedCL)
        let confirmed = (telemetry.isProducedByAccessory == true) && distance < 500.0

        if confirmed != isAccessoryLocationConfirmed {
            isAccessoryLocationConfirmed = confirmed
            session?.markCoreLocationConfirmed(confirmed)
            if confirmed {
                needsLocationServiceRefresh = false
                lockWatchdogTask?.cancel()
                lockWatchdogTask = nil
                RelocTheme.hapticSuccess()
                events.append(ProtocolEvent(
                    name: "accessory_location_confirmed",
                    detail: String(format: "{\"event\":\"accessory_location_confirmed\",\"distance_m\":%.1f,\"accuracy_m\":%.1f}", distance, telemetry.horizontalAccuracy)
                ))
                if isLocationRefreshGuideActive {
                    isLocationRefreshGuideActive = false
                    refreshCountdownTask?.cancel()
                    refreshCountdownTask = nil
                    PairingPiPPresenter.shared.finishLocationRefresh(
                        succeeded: true,
                        message: "已锁定「\(selectedPlaceName)」，可返回任意 App 使用"
                    )
                }
            }
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
    public func launchOneTapLocationRefresh() {
        guard snapshot.isRunning else { return }
        // Cancel background pulse/watchdog tasks immediately so they never stop CLLocationManager
        // and falsely trigger a 0xFFFC "5 秒" flash before the user touches Location Services.
        cancelTriggerTasks()
        isLocationRefreshGuideActive = true
        locationRefreshSawDisabled = false
        lastRestoreAuthStatus = coreLocation.authorizationStatus
        PairingPiPPresenter.shared.startLocationRefreshGuide()
        session?.triggerFastBurst(seconds: 30.0)
        // Wait briefly for PiP to enter smoothly before switching to Settings (prevents stutter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isLocationRefreshGuideActive, self.snapshot.isRunning else { return }
            self.openLocationServicesSettings()
        }
    }

    /// Manually pulses CoreLocation and triggers a fast NMEA burst without leaving Reloc.
    public func retryAutoLock() {
        guard snapshot.isRunning else { return }
        needsLocationServiceRefresh = false
        session?.triggerFastBurst(seconds: 15.0)
        keepAlive.pulseLocationSubscription()
        coreLocation.pulseForAccessoryLock()
        scheduleLockWatchdog()
    }

    private func startLocationRefreshCountdown() {
        refreshCountdownTask?.cancel()
        refreshCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 5, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.isLocationRefreshGuideActive else { return }
                PairingPiPPresenter.shared.updateLocationRefresh(
                    step: 2,
                    headline: "② 正在清空系统定位缓存",
                    subtitle: "请保持「定位服务」关闭，等待倒计时结束",
                    countdown: remaining
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self, self.isLocationRefreshGuideActive else { return }
            RelocTheme.hapticMedium()
            PairingPiPPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: "③ 请重新打开「定位服务」",
                subtitle: "打开开关后 Reloc 将自动 100% 锁定外设 GPS",
                countdown: 0
            )
        }
    }

    public func openLocationServicesSettings() {
        let candidates = [
            "App-Prefs:Privacy&path=LOCATION",
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

    // MARK: - Pairing & Places Management

    public func reloadPairing() {
        let (pairing, pairStat) = store.loadPairing()
        self.savedPairing = pairing
        self.pairingStatus = pairStat
        self.deviceUDID = store.deviceUDID
    }

    public func importPairingFile(url: URL) {
        do {
            _ = try store.importPairingFile(from: url)
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(name: "pairing_imported", detail: "{\"event\":\"pairing_imported\"}"))
            testConnection(silent: true)
        } catch {
            alertMessage = "配对文件导入失败：\(error.localizedDescription)"
        }
    }

    public func removePairingFile() {
        store.removePairingFile()
        reloadPairing()
        invalidateDeviceConnection()
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
    }

    public func saveCurrentAsFavorite(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let loc = inspectedLocation
        favorites.insert(
            FavoriteLocation(
                name: trimmed,
                subtitle: selectedPlaceAddress,
                latitude: loc.latitude,
                longitude: loc.longitude,
                altitude: loc.altitude
            ),
            at: 0
        )
        store.saveFavorites(favorites)
    }

    public func renameFavorite(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[idx].name = trimmed
        store.saveFavorites(favorites)
    }

    public func deleteFavorite(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        store.saveFavorites(favorites)
    }

    public func deleteFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        store.saveFavorites(favorites)
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
}
