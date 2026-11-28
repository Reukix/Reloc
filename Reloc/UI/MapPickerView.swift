import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct MapPickerView: View {
    @ObservedObject var viewModel: RelocViewModel
    let switchToConfig: () -> Void

    @State private var searchText = ""
    @State private var searchResults: [PlaceSearchResult] = []
    @State private var isSearching = false
    @State private var searchStatusMessage: String?
    @State private var activeSearch: MKLocalSearch?
    @State private var activeNominatimSearchTask: Task<Void, Never>?
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @FocusState private var isSearchFocused: Bool
    @State private var cameraTarget: CLLocationCoordinate2D?
    @State private var visibleMapRegion: MKCoordinateRegion?
    @State private var showManualCoordinate = false
    @State private var showPlacesSheet = false
    @State private var showProxyRulesSheet = false
    @State private var showRouteGoalSheet = false
    @State private var showStopConfirm = false
    @State private var showSaveRouteAlert = false
    @State private var saveRouteName = ""
    @State private var copiedAddressToast = false
    @State private var showGPXImporter = false
    @State private var showBackupImporter = false
    @State private var sharedFileItem: SharedFileItem?

    private var isRouteMode: Bool {
        viewModel.controlMode == .route || viewModel.isRouteSessionActive
    }

    private var isJoystickMode: Bool {
        viewModel.controlMode == .joystick || viewModel.isJoystickSessionActive
    }

    private var hasSearchDropdown: Bool {
        !searchResults.isEmpty
            || !searchCompleter.suggestions.isEmpty
            || searchStatusMessage != nil
    }

    private var currentSearchRegion: MKCoordinateRegion {
        if let region = visibleMapRegion {
            if viewModel.mapSource.isPureWGS84,
               viewModel.gcj02CorrectionEnabled,
               !CoordinateTransform.isOutsideChina(lat: region.center.latitude, lon: region.center.longitude) {
                let gcjCenter = CoordinateTransform.wgs84ToGCJ02(lat: region.center.latitude, lon: region.center.longitude)
                return MKCoordinateRegion(center: gcjCenter, span: region.span)
            }
            return region
        }
        return MKCoordinateRegion(
            center: viewModel.activeMapCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    }

    init(viewModel: RelocViewModel, switchToConfig: @escaping () -> Void) {
        self.viewModel = viewModel
        self.switchToConfig = switchToConfig
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.mapSource.isPureWGS84 {
                WebMercatorMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: (isRouteMode || viewModel.isJoystickSessionActive) ? nil : viewModel.pendingMapCoordinate,
                    routePolyline: viewModel.routeMapPolylineCoordinates,
                    routeWaypoints: viewModel.routeMapWaypointCoordinates,
                    showActivePin: !isRouteMode || viewModel.isRouteSessionActive || viewModel.routeStartPreviewCoordinate != nil,
                    isFreehandDrawing: viewModel.isFreehandDrawing,
                    canDragRouteWaypoints: viewModel.canDragRouteWaypoints,
                    mapSource: viewModel.mapSource,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        handleMapTap(coord)
                    },
                    onRegionChange: { region in
                        visibleMapRegion = region
                    },
                    onFinishFreehandStroke: { coords in
                        RelocTheme.hapticMedium()
                        viewModel.commitFreehandStroke(mapCoordinates: coords)
                    },
                    onMoveRouteWaypoint: { index, coord in
                        RelocTheme.hapticMedium()
                        viewModel.moveRouteWaypoint(at: index, toMapCoordinate: coord)
                    }
                )
                .ignoresSafeArea()
            } else {
                InteractiveMKMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: (isRouteMode || viewModel.isJoystickSessionActive) ? nil : viewModel.pendingMapCoordinate,
                    routePolyline: viewModel.routeMapPolylineCoordinates,
                    routeWaypoints: viewModel.routeMapWaypointCoordinates,
                    showActivePin: !isRouteMode || viewModel.isRouteSessionActive || viewModel.routeStartPreviewCoordinate != nil,
                    isFreehandDrawing: viewModel.isFreehandDrawing,
                    canDragRouteWaypoints: viewModel.canDragRouteWaypoints,
                    mapStyle: viewModel.mapStyle,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        handleMapTap(coord)
                    },
                    onRegionChange: { region in
                        visibleMapRegion = region
                    },
                    onFinishFreehandStroke: { coords in
                        RelocTheme.hapticMedium()
                        viewModel.commitFreehandStroke(mapCoordinates: coords)
                    },
                    onMoveRouteWaypoint: { index, coord in
                        RelocTheme.hapticMedium()
                        viewModel.moveRouteWaypoint(at: index, toMapCoordinate: coord)
                    }
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                Spacer(minLength: 0)

                if !viewModel.isFreehandDrawing {
                    HStack(alignment: .bottom) {
                        if viewModel.isJoystickSessionActive {
                            JoystickPadView(
                                headingDegrees: viewModel.joystickProgress?.headingDegrees ?? 0,
                                isMoving: viewModel.joystickProgress?.isMoving ?? false,
                                isCruiseLocked: viewModel.joystickCruiseLocked,
                                isWaitingForLock: viewModel.joystickProgress?.isWaitingForStartLock ?? true,
                                onVectorChange: { mag, heading in
                                    viewModel.updateJoystickInput(magnitude: mag, headingDegrees: heading)
                                },
                                onToggleCruise: {
                                    viewModel.toggleJoystickCruiseLock()
                                }
                            )
                        }
                        Spacer()
                        rightControlDock
                    }
                }

                if viewModel.isFreehandDrawing && !viewModel.isRouteSessionActive {
                    compactFreehandDrawingCard
                } else if isRouteMode {
                    routeControlCard
                } else if isJoystickMode {
                    joystickControlCard
                } else {
                    fixedLocationCard
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 10) {
                if viewModel.isFreehandDrawing && !viewModel.isRouteSessionActive {
                    freehandDrawingBanner
                } else {
                    searchBar
                    if hasSearchDropdown {
                        searchDropdownCard
                    } else {
                        topStatusRow

                        if let interrupted = viewModel.interruptedSession, !viewModel.snapshot.isRunning {
                            interruptedRecoveryBanner(interrupted)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbarBackground(.hidden, for: .tabBar)
        .relocOnChange(of: searchText) { newValue in
            handleSearchTextChange(newValue)
        }
        .relocOnChange(of: isSearchFocused) { focused in
            if focused {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, searchCompleter.suggestions.isEmpty, searchResults.isEmpty {
                    handleSearchTextChange(trimmed)
                }
            }
        }
        .sheet(isPresented: $showManualCoordinate) {
            ManualCoordinateSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .sheet(isPresented: $showPlacesSheet) {
            PlacesSheet(
                viewModel: viewModel,
                onSelect: { coord in
                    cameraTarget = coord
                },
                onImportGPX: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showGPXImporter = true
                    }
                },
                onExportGPX: { route in
                    if let url = viewModel.exportSavedRouteToGPX(route) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            sharedFileItem = SharedFileItem(url: url)
                        }
                    }
                },
                onExportFavoriteGPX: { fav in
                    if let url = viewModel.exportFavoriteToGPX(fav) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            sharedFileItem = SharedFileItem(url: url)
                        }
                    }
                },
                onExportBackup: {
                    if let url = viewModel.exportBackupArchive() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            sharedFileItem = SharedFileItem(url: url)
                        }
                    }
                },
                onImportBackup: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showBackupImporter = true
                    }
                }
            )
        }
        .sheet(item: $sharedFileItem) { item in
            ActivityShareSheet(url: item.url)
        }
        .sheet(isPresented: $showProxyRulesSheet) {
            AntiSnapbackRulesSheet()
        }
        .sheet(isPresented: $showRouteGoalSheet) {
            RouteGoalSheet(viewModel: viewModel)
                .presentationDetents([.fraction(0.62), .large])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showGPXImporter,
            allowedContentTypes: [.relocGPX, .xml],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if viewModel.importGPXFile(from: url) {
                    RelocTheme.hapticSuccess()
                }
            case .failure(let error):
                viewModel.alertMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.json, .relocGPX, .xml],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if viewModel.importDataFile(from: url) {
                    RelocTheme.hapticSuccess()
                }
            case .failure(let error):
                viewModel.alertMessage = error.localizedDescription
            }
        }
        .onReceive(viewModel.$pendingCameraFocus.compactMap { $0 }) { coord in
            cameraTarget = coord
            viewModel.pendingCameraFocus = nil
        }
        .confirmationDialog(L10n.tr("map.stop_confirm.title"), isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button(L10n.tr("map.stop_confirm.button"), role: .destructive) {
                RelocTheme.hapticMedium()
                viewModel.stopAndRestore()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("map.stop_confirm.message"))
        }
        .alert(L10n.tr("route.save.title"), isPresented: $showSaveRouteAlert) {
            TextField(L10n.tr("route.save.placeholder"), text: $saveRouteName)
            Button(L10n.tr("common.cancel"), role: .cancel) {
                saveRouteName = ""
            }
            Button(L10n.tr("common.save")) {
                viewModel.saveCurrentRoute(name: saveRouteName)
                saveRouteName = ""
                RelocTheme.hapticSuccess()
            }
        } message: {
            Text(L10n.tr("route.save.message"))
        }
    }

    // MARK: - Top Search Bar & Status Row

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    performSearch()
                } else {
                    isSearchFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RelocTheme.accent)
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField(
                isRouteMode ? L10n.tr("route.search.placeholder") : L10n.tr("map.search.placeholder"),
                text: $searchText
            )
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit { performSearch() }
                .frame(maxWidth: .infinity, minHeight: 44)

            Group {
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("map.search.clear"))
                } else {
                    Button {
                        RelocTheme.hapticLight()
                        dismissSearchOverlay()
                        showManualCoordinate = true
                    } label: {
                        Image(systemName: "number.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("map.search.manual"))
                }
            }
            .frame(width: 28, height: 44)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .contentShape(Capsule())
                .onTapGesture {
                    isSearchFocused = true
                }
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var statusPillButton: some View {
        Button(action: switchToConfig) {
            HStack(spacing: 6) {
                PulsingStatusDot(
                    color: statusDotColor,
                    isPulsing: viewModel.snapshot.isRunning
                )
                Text(statusPillTitle)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6.5)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var topStatusRow: some View {
        if viewModel.snapshot.isRunning {
            HStack(spacing: 8) {
                statusPillButton
                Spacer(minLength: 4)
                let live = viewModel.currentLiveCoordinateSummary
                HStack(spacing: 5) {
                    Image(
                        systemName: viewModel.isRouteSessionActive
                            ? viewModel.routePreset.systemImage
                            : (viewModel.isJoystickSessionActive ? "gamecontroller.fill" : "location.fill")
                    )
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.emerald)
                    if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
                        if viewModel.routePreset == .running, let pace = RouteGeometry.formatPacePerKm(prog.currentSpeedMps) {
                            Text("\(pace) · \(Int((prog.progress * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        } else {
                            Text("\(RouteGeometry.formatSpeedKmh(prog.currentSpeedMps)) · \(Int((prog.progress * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    } else if viewModel.isJoystickSessionActive, let joy = viewModel.joystickProgress {
                        Text("\(RouteGeometry.formatHeading(joy.headingDegrees)) · \(RouteGeometry.formatSpeedKmh(joy.currentSpeedMps))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    } else {
                        Text(String(format: "%.4f, %.4f · %.0fm", live.latitude, live.longitude, live.altitude))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                modeTogglePill
                HStack {
                    statusPillButton
                    Spacer()
                }
            }
        }
    }

    private var modeTogglePill: some View {
        HStack(spacing: 3) {
            ForEach(LocationControlMode.allCases) { mode in
                let selected = viewModel.controlMode == mode
                Button {
                    guard viewModel.controlMode != mode else { return }
                    RelocTheme.hapticLight()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.controlMode = mode
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11, weight: .bold))
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6.5)
                    .background(selected ? RelocTheme.accent : Color.clear, in: Capsule())
                    .foregroundStyle(selected ? .white : .primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private var rightControlDock: some View {
        VStack(spacing: 10) {
            MapHUDIconButton(systemName: "bookmark.fill") {
                showPlacesSheet = true
            }

            Menu {
                Section(L10n.tr("map.menu.source")) {
                    ForEach(MapSource.allCases) { source in
                        Button {
                            viewModel.mapSource = source
                        } label: {
                            Label(source.shortTitle, systemImage: viewModel.mapSource == source ? "checkmark" : "globe")
                        }
                    }
                }
                if viewModel.mapSource == .appleNative {
                    Section(L10n.tr("map.menu.style")) {
                        ForEach(MapDisplayStyle.allCases) { style in
                            Button {
                                viewModel.mapStyle = style
                            } label: {
                                Label(style.title, systemImage: viewModel.mapStyle == style ? "checkmark" : "map")
                            }
                        }
                    }
                }
                Section(L10n.tr("map.menu.coordinates")) {
                    Button { showManualCoordinate = true } label: {
                        Label(L10n.tr("map.menu.manual_input"), systemImage: "number")
                    }
                    if !viewModel.isRouteSessionActive {
                        Button { showGPXImporter = true } label: {
                            Label(L10n.tr("gpx.action.import"), systemImage: "square.and.arrow.down")
                        }
                    }
                    Button {
                        if isRouteMode && viewModel.plannedRoutePoints.count >= 2 {
                            if let url = viewModel.exportCurrentRouteToGPX(suggestedName: defaultRouteSaveName) {
                                sharedFileItem = SharedFileItem(url: url)
                            }
                        } else if let url = viewModel.exportCurrentPinToGPX() {
                            sharedFileItem = SharedFileItem(url: url)
                        }
                    } label: {
                        Label(L10n.tr("gpx.action.export"), systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            }
            .tint(.primary)

            MapHUDIconButton(systemName: viewModel.snapshot.isRunning ? "scope" : "location.fill") {
                if !viewModel.snapshot.isRunning, let real = viewModel.coreLocation.latest {
                    cameraTarget = viewModel.toMapCoordinate(CLLocationCoordinate2D(latitude: real.latitude, longitude: real.longitude))
                } else {
                    viewModel.coreLocation.requestOneShot()
                    cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
                }
            }
        }
    }

    private var freehandDrawingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "scribble.variable")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RelocTheme.accent, in: Circle())
            Text(L10n.tr("route.freehand.banner"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L10n.tr("route.freehand.stop_draw")) {
                RelocTheme.hapticLight()
                viewModel.cancelFreehandDrawing()
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RelocTheme.amber, in: Capsule())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RelocTheme.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private var compactFreehandDrawingCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("route.freehand.drawing_title"))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(L10n.tr("route.freehand.drawing_subtitle"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if viewModel.canUndoFreehandRoute {
                routeMiniIconButton("arrow.uturn.backward") {
                    viewModel.undoLastRouteWaypoint()
                }
            }
            Button(L10n.tr("route.freehand.stop_draw")) {
                RelocTheme.hapticLight()
                viewModel.cancelFreehandDrawing()
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.16), in: Capsule())
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
        .relocGlassCard(cornerRadius: 20, padding: 12)
    }

    private var statusDotColor: Color {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return RelocTheme.emerald
        case .injectingPendingLock, .waitingSubscription:
            return viewModel.needsLocationServiceRefresh ? RelocTheme.amber : RelocTheme.accent
        case .connecting:
            return RelocTheme.amber
        case .idle:
            return RelocTheme.accent
        }
    }

    private var statusPillTitle: String {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return L10n.tr("map.status.confirmed")
        case .injectingPendingLock:
            return viewModel.needsLocationServiceRefresh
                ? L10n.format("map.status.pending_refresh", viewModel.snapshot.packetsAcknowledged)
                : L10n.format("map.status.switching", viewModel.snapshot.packetsAcknowledged)
        case .waitingSubscription:
            return viewModel.needsLocationServiceRefresh ? L10n.tr("map.status.auth_refresh") : L10n.tr("map.status.auth_waking")
        case .connecting:
            return L10n.tr("map.status.connecting")
        case .idle:
            return L10n.tr("map.status.idle")
        }
    }

    private var searchCompletionsContent: some View {
        let items = Array(searchCompleter.suggestions.prefix(6).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.element.id) { index, suggestion in
                Button {
                    selectSuggestion(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.isDirectMapItem ? "mappin.circle.fill" : "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(suggestion.isDirectMapItem ? RelocTheme.accent : Color(uiColor: .secondaryLabel))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(suggestion.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .label))
                                    .lineLimit(1)
                                if suggestion.isOSMResult {
                                    Text("OSM")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(RelocTheme.emerald.opacity(0.16), in: Capsule())
                                        .foregroundStyle(RelocTheme.emerald)
                                }
                            }
                            if let subtitle = suggestion.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color(uiColor: .separator).opacity(0.45))
                        .frame(height: 0.5)
                        .padding(.leading, 44)
                }
            }
        }
    }

    private var searchResultsContent: some View {
        let items = Array(searchResults.prefix(6).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.element.id) { index, item in
                Button {
                    applyPlaceResultSelection(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isOSMResult ? "globe" : "mappin.circle.fill")
                            .foregroundStyle(item.isOSMResult ? RelocTheme.emerald : RelocTheme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .label))
                                    .lineLimit(1)
                                if item.isOSMResult {
                                    Text("OSM")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(RelocTheme.emerald.opacity(0.16), in: Capsule())
                                        .foregroundStyle(RelocTheme.emerald)
                                }
                            }
                            if let subtitle = item.address, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color(uiColor: .separator).opacity(0.45))
                        .frame(height: 0.5)
                        .padding(.leading, 44)
                }
            }
        }
    }

    @ViewBuilder
    private var searchDropdownCard: some View {
        Group {
            if !searchResults.isEmpty {
                ViewThatFits(in: .vertical) {
                    searchResultsContent
                    ScrollView {
                        searchResultsContent
                    }
                }
                .frame(maxHeight: 240)
            } else if !searchCompleter.suggestions.isEmpty {
                ViewThatFits(in: .vertical) {
                    searchCompletionsContent
                    ScrollView {
                        searchCompletionsContent
                    }
                }
                .frame(maxHeight: 240)
            } else if let message = searchStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture {}
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private func interruptedRecoveryBanner(_ record: InterruptedSessionRecord) -> some View {
        HStack(spacing: 10) {
            SettingsIconBadge(systemName: "arrow.counterclockwise", color: RelocTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("map.interrupted.title"))
                    .font(.caption.weight(.bold))
                Text(L10n.format("map.interrupted.subtitle", record.placeName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.tr("common.restore")) {
                RelocTheme.hapticMedium()
                viewModel.resumeInterruptedSession()
                cameraTarget = viewModel.activeMapCoordinate
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RelocTheme.amber, in: Capsule())
            .foregroundStyle(.white)

            Button {
                viewModel.dismissInterruptedSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(RelocTheme.amber.opacity(0.35), lineWidth: 0.8))
    }

    // MARK: - Bottom Fixed Location Card

    private var sheetGrabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var fixedLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sheetGrabber

            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((viewModel.pendingLocation != nil ? RelocTheme.amber : (viewModel.snapshot.isRunning ? RelocTheme.emerald : RelocTheme.accent)).opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: viewModel.pendingLocation != nil ? "mappin.and.ellipse" : (viewModel.snapshot.isRunning ? "location.fill" : "mappin.circle.fill"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(viewModel.pendingLocation != nil ? RelocTheme.amber : (viewModel.snapshot.isRunning ? RelocTheme.emerald : RelocTheme.accent))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedPlaceName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(viewModel.selectedPlaceAddress.isEmpty
                             ? String(format: "%.5f, %.5f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude)
                             : viewModel.selectedPlaceAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            let text = "\(viewModel.selectedPlaceName) (\(String(format: "%.6f, %.6f, %.1fm", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude, viewModel.inspectedLocation.altitude)))"
                            UIPasteboard.general.string = text
                            RelocTheme.hapticLight()
                            copiedAddressToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedAddressToast = false }
                        } label: {
                            Image(systemName: copiedAddressToast ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(copiedAddressToast ? RelocTheme.emerald : RelocTheme.accent)
                        }
                    }
                    HStack(spacing: 6) {
                        Button {
                            RelocTheme.hapticLight()
                            showManualCoordinate = true
                        } label: {
                            HStack(spacing: 3) {
                                if viewModel.isResolvingAltitude {
                                    ProgressView().controlSize(.mini)
                                    Text(L10n.tr("map.altitude.resolving"))
                                } else {
                                    Group {
                                        if #available(iOS 16.1, *) {
                                            Image(systemName: "mountain.2.fill")
                                        } else {
                                            Image(systemName: "arrow.up.and.down")
                                        }
                                    }
                                    .font(.system(size: 9, weight: .semibold))
                                    Text(L10n.format("map.altitude.value", viewModel.inspectedLocation.altitude))
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RelocTheme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(RelocTheme.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Text(String(format: "%.5f, %.5f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let distMeters = viewModel.distanceFromRealLocationMeters {
                            distanceFromRealPill(distMeters)
                        }
                    }
                }

                Spacer()

                Button {
                    RelocTheme.hapticLight()
                    viewModel.toggleFavoriteForInspected()
                } label: {
                    Image(systemName: viewModel.isCurrentInspectedFavorite ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.isCurrentInspectedFavorite ? .pink : .secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }

                if viewModel.pendingLocation != nil {
                    Button {
                        viewModel.clearPendingSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.secondary.opacity(0.12), in: Circle())
                    }
                }
            }

            if viewModel.locationAuthorizationStatus == .denied || viewModel.locationAuthorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text(L10n.tr("map.permission.denied")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.crimson, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.isLocationReducedAccuracy {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.permission.reduced")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.amber, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.realLocationRestoredNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelocTheme.emerald)
                    Text(L10n.tr("map.restored.notice"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelocTheme.emerald)
                    Spacer()
                }
                .padding(10)
                .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let err = viewModel.snapshot.lastError {
                Text(L10n.format("map.last_error", err))
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            } else if viewModel.isInspectedLocationDistant, let distMeters = viewModel.distanceFromRealLocationMeters {
                distantLocationWarningBanner(distMeters)
            }

            HStack(spacing: 10) {
                if viewModel.snapshot.isRunning {
                    if viewModel.pendingLocation != nil {
                        RelocPrimaryButton(
                            title: L10n.tr("map.button.update_location"),
                            systemImage: "paperplane.fill",
                            gradient: RelocTheme.accentGradient
                        ) {
                            viewModel.applyPendingLocationUpdate()
                        }
                    }
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.stop_restore"),
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.start"),
                        systemImage: "paperplane.fill",
                        gradient: RelocTheme.accentGradient,
                        disabled: !viewModel.canStartSession
                    ) {
                        viewModel.start(mode: .send)
                    }
                }
            }
        }
        .relocGlassCard(cornerRadius: 24, padding: 15)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {}
        }
    }

    private func distanceFromRealPill(_ meters: Double) -> some View {
        let distant = meters > 15_000.0
        return HStack(spacing: 3) {
            Image(systemName: distant ? "exclamationmark.triangle.fill" : "ruler")
                .font(.system(size: 8.5, weight: .bold))
            Text(RouteGeometry.formatDistance(meters))
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(distant ? RelocTheme.amber : .secondary)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2)
        .background((distant ? RelocTheme.amber.opacity(0.16) : Color.secondary.opacity(0.12)), in: Capsule())
    }

    private func distantLocationWarningBanner(_ meters: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane.circle.fill")
                .foregroundStyle(RelocTheme.amber)
            Text(L10n.format("map.distant.warning", RouteGeometry.formatDistance(meters)))
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L10n.tr("map.distant.rules_button")) {
                RelocTheme.hapticLight()
                showProxyRulesSheet = true
            }
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RelocTheme.amber.opacity(0.18), in: Capsule())
            .foregroundStyle(RelocTheme.amber)
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(RelocTheme.amber.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Bottom Joystick Control Card

    private var joystickControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sheetGrabber

            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((viewModel.isJoystickSessionActive ? RelocTheme.emerald : RelocTheme.accent).opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(viewModel.isJoystickSessionActive ? RelocTheme.emerald : RelocTheme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(joystickHeaderTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(joystickHeaderSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let distMeters = viewModel.distanceFromRealLocationMeters, !viewModel.snapshot.isRunning {
                    distanceFromRealPill(distMeters)
                }
            }

            // 4 Quick Speed Presets
            HStack(spacing: 6) {
                ForEach(RouteTransportPreset.allCases) { preset in
                    let isClose = abs(viewModel.joystickSpeedMps - preset.defaultSpeedMps) < 0.35
                    Button {
                        RelocTheme.hapticLight()
                        viewModel.joystickSpeedMps = preset.defaultSpeedMps
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: preset.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                            Text(preset.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isClose ? RelocTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(isClose ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Real-time Speed Slider
            VStack(spacing: 2) {
                HStack {
                    Text(L10n.tr("joystick.speed.label"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(joystickSpeedLabel(viewModel.joystickSpeedMps))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(RelocTheme.accent)
                }
                Slider(value: $viewModel.joystickSpeedMps, in: 0.5...25.0, step: 0.2)
                    .tint(RelocTheme.accent)
            }

            if viewModel.locationAuthorizationStatus == .denied || viewModel.locationAuthorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text(L10n.tr("map.permission.denied")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) { viewModel.openAppSettings() }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RelocTheme.crimson, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.isLocationReducedAccuracy {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.permission.reduced")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) { viewModel.openAppSettings() }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RelocTheme.amber, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.isInspectedLocationDistant, let distMeters = viewModel.distanceFromRealLocationMeters {
                distantLocationWarningBanner(distMeters)
            }

            HStack(spacing: 10) {
                if viewModel.isJoystickSessionActive {
                    RelocPrimaryButton(
                        title: viewModel.joystickCruiseLocked ? L10n.tr("joystick.cruise.unlock") : L10n.tr("joystick.cruise.lock"),
                        systemImage: viewModel.joystickCruiseLocked ? "lock.open.fill" : "lock.fill",
                        gradient: viewModel.joystickCruiseLocked
                            ? LinearGradient(colors: [RelocTheme.amber, Color(red: 0.85, green: 0.48, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : RelocTheme.emeraldGradient
                    ) {
                        viewModel.toggleJoystickCruiseLock()
                    }
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.stop_restore"),
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: L10n.tr("joystick.button.start"),
                        systemImage: "gamecontroller.fill",
                        gradient: RelocTheme.accentGradient,
                        disabled: !viewModel.canStartSession
                    ) {
                        viewModel.startJoystickSession()
                    }
                }
            }
        }
        .relocGlassCard(cornerRadius: 24, padding: 14)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {}
        }
    }

    private var joystickHeaderTitle: String {
        if viewModel.isJoystickSessionActive, let joy = viewModel.joystickProgress {
            if joy.isWaitingForStartLock {
                return L10n.tr("joystick.status.waiting_lock")
            } else if joy.isCruiseLocked {
                return L10n.tr("joystick.status.cruising")
            } else if joy.isMoving {
                return L10n.tr("joystick.status.moving")
            } else {
                return L10n.tr("joystick.status.ready")
            }
        }
        return L10n.format("joystick.idle.title", viewModel.selectedPlaceName)
    }

    private var joystickHeaderSubtitle: String {
        if viewModel.isJoystickSessionActive, let joy = viewModel.joystickProgress {
            let heading = RouteGeometry.formatHeading(joy.headingDegrees)
            let speed = RouteGeometry.formatSpeedKmh(joy.currentSpeedMps)
            let dist = RouteGeometry.formatDistance(joy.traveledMeters)
            return "\(heading) · \(speed) · \(dist)"
        }
        return L10n.tr("joystick.idle.subtitle")
    }

    private func joystickSpeedLabel(_ mps: Double) -> String {
        let kmh = RouteGeometry.formatSpeedKmh(mps)
        if mps <= 6.5, let pace = RouteGeometry.formatPacePerKm(mps) {
            return "\(kmh) · \(pace)"
        }
        return String(format: "%@ (%.1f m/s)", kmh, mps)
    }

    // MARK: - Bottom Trajectory / Route Control Card

    private var routeControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sheetGrabber

            // Header: Route title, stats & quick edit buttons
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((viewModel.isRouteSessionActive ? RelocTheme.emerald : RelocTheme.accent).opacity(0.16))
                        .frame(width: 40, height: 40)
                    if viewModel.isPlanningRoute {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: viewModel.isRouteSessionActive ? viewModel.routePreset.systemImage : viewModel.routeCreationMode.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(viewModel.isRouteSessionActive ? RelocTheme.emerald : RelocTheme.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(routeHeaderTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(routeHeaderSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if !viewModel.isRouteSessionActive {
                    if !viewModel.routeWaypoints.isEmpty || viewModel.plannedRoutePoints.count >= 2 {
                        HStack(spacing: 6) {
                            routeMiniIconButton("arrow.uturn.backward") {
                                viewModel.undoLastRouteWaypoint()
                            }
                            Menu {
                                if viewModel.plannedRoutePoints.count >= 2 || viewModel.routeWaypoints.count >= 2 {
                                    Button {
                                        RelocTheme.hapticLight()
                                        viewModel.reverseRouteWaypoints()
                                    } label: {
                                        Label(L10n.tr("route.action.reverse"), systemImage: "arrow.up.arrow.down")
                                    }
                                }
                                if viewModel.plannedRoutePoints.count >= 2 && !viewModel.isPlanningRoute {
                                    Button {
                                        saveRouteName = defaultRouteSaveName
                                        showSaveRouteAlert = true
                                    } label: {
                                        Label(L10n.tr("route.save.title"), systemImage: "bookmark")
                                    }
                                    Button {
                                        if let url = viewModel.exportCurrentRouteToGPX(suggestedName: defaultRouteSaveName) {
                                            sharedFileItem = SharedFileItem(url: url)
                                        }
                                    } label: {
                                        Label(L10n.tr("gpx.action.export"), systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button {
                                    showGPXImporter = true
                                } label: {
                                    Label(L10n.tr("gpx.action.import"), systemImage: "square.and.arrow.down")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    RelocTheme.hapticMedium()
                                    viewModel.clearRoute()
                                } label: {
                                    Label(L10n.tr("common.clear"), systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color(uiColor: .label).opacity(0.75))
                                    .frame(width: 30, height: 30)
                                    .background(Color.secondary.opacity(0.12), in: Circle())
                            }
                            .tint(.primary)
                        }
                    } else {
                        Button {
                            RelocTheme.hapticLight()
                            showGPXImporter = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 10.5, weight: .bold))
                                Text(L10n.tr("gpx.action.import_short"))
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                            .foregroundStyle(RelocTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !viewModel.isRouteSessionActive {
                HStack(spacing: 6) {
                    ForEach(RouteCreationMode.allCases) { mode in
                        let selected = viewModel.routeCreationMode == mode
                        Button {
                            RelocTheme.hapticLight()
                            withAnimation(.easeInOut(duration: 0.16)) {
                                viewModel.routeCreationMode = mode
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.systemImage)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(mode.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(selected ? RelocTheme.accent.opacity(0.16) : Color.secondary.opacity(0.10), in: Capsule())
                            .foregroundStyle(selected ? RelocTheme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 4)

                    if viewModel.routeCreationMode == .freehand {
                        Button {
                            RelocTheme.hapticLight()
                            if viewModel.isFreehandDrawing {
                                viewModel.cancelFreehandDrawing()
                            } else {
                                viewModel.beginFreehandDrawing()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: viewModel.isFreehandDrawing ? "xmark" : "pencil")
                                    .font(.system(size: 10, weight: .bold))
                                Text(
                                    viewModel.isFreehandDrawing
                                        ? L10n.tr("route.freehand.stop_draw")
                                        : (viewModel.plannedRoutePoints.count >= 2
                                            ? L10n.tr("route.freehand.redraw")
                                            : L10n.tr("route.freehand.start_draw"))
                                )
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(viewModel.isFreehandDrawing ? RelocTheme.amber : RelocTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let notice = viewModel.routePlanningNotice, !viewModel.isRouteSessionActive {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.amber)
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
                // Live trajectory progress & speed control
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: prog.progress)
                        .tint(prog.isPaused ? RelocTheme.amber : RelocTheme.emerald)

                    HStack(spacing: 8) {
                        Image(systemName: "speedometer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RelocTheme.accent)
                        Text(liveSpeedLabel(prog.currentSpeedMps))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                        Slider(
                            value: $viewModel.routeSpeedMps,
                            in: viewModel.routePreset.speedRangeMps,
                            step: viewModel.routePreset.speedStepMps
                        )
                        .tint(RelocTheme.accent)
                    }
                }
            } else {
                // 4 Transport Presets
                HStack(spacing: 6) {
                    ForEach(RouteTransportPreset.allCases) { preset in
                        let selected = viewModel.routePreset == preset
                        Button {
                            RelocTheme.hapticLight()
                            viewModel.routePreset = preset
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: preset.systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(preset.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6.5)
                            .background(selected ? RelocTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(selected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Speed Slider + Pace/km/h readout
                VStack(spacing: 2) {
                    HStack {
                        Text(L10n.tr("route.speed.label"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(configuredSpeedLabel)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(RelocTheme.accent)
                    }
                    Slider(
                        value: $viewModel.routeSpeedMps,
                        in: viewModel.routePreset.speedRangeMps,
                        step: viewModel.routePreset.speedStepMps
                    )
                    .tint(RelocTheme.accent)
                }

                // Loop Mode + Realistic Motion toggle
                HStack(spacing: 6) {
                    ForEach(RouteLoopMode.allCases) { loop in
                        let selected = viewModel.routeLoopMode == loop
                        Button {
                            RelocTheme.hapticLight()
                            viewModel.routeLoopMode = loop
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: loop.systemImage)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(loop.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5.5)
                            .background(selected ? RelocTheme.accent.opacity(0.16) : Color.secondary.opacity(0.10), in: Capsule())
                            .foregroundStyle(selected ? RelocTheme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 2)

                    Button {
                        RelocTheme.hapticLight()
                        viewModel.routeRealisticMotionEnabled.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.tr("route.realistic.short"))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5.5)
                        .background(
                            viewModel.routeRealisticMotionEnabled ? RelocTheme.emerald.opacity(0.16) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.routeRealisticMotionEnabled ? RelocTheme.emerald : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Stop Goal + Brief Stops Row
                HStack(spacing: 6) {
                    Button {
                        RelocTheme.hapticLight()
                        showRouteGoalSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.routeStopGoalKind.systemImage)
                                .font(.system(size: 10, weight: .bold))
                            Text(routeGoalSummaryLabel)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(
                            viewModel.routeStopGoalKind != .none ? RelocTheme.accent.opacity(0.16) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.routeStopGoalKind != .none ? RelocTheme.accent : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        RelocTheme.hapticLight()
                        viewModel.routeBriefStopsEnabled.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pause.circle")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.tr("route.brief_stops.short"))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(
                            viewModel.routeBriefStopsEnabled ? RelocTheme.amber.opacity(0.16) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.routeBriefStopsEnabled ? RelocTheme.amber : .secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 2)

                    if let distMeters = viewModel.distanceFromRealLocationMeters {
                        distanceFromRealPill(distMeters)
                    }
                }

                // Mid-route start progress scrubber when route is ready
                if viewModel.plannedRoutePoints.count >= 2 && !viewModel.isPlanningRoute {
                    HStack(spacing: 8) {
                        Text(L10n.tr("route.start_progress.label"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Slider(value: $viewModel.routeStartProgress, in: 0.0...0.95, step: 0.01)
                            .tint(RelocTheme.emerald)
                        Text(
                            viewModel.routeStartProgress > 0.005
                                ? "\(Int((viewModel.routeStartProgress * 100).rounded()))%"
                                : L10n.tr("route.pin.start")
                        )
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(viewModel.routeStartProgress > 0.005 ? RelocTheme.emerald : .secondary)
                        .frame(minWidth: 34, alignment: .trailing)
                    }
                }
            }

            // Shared permission / live / restore / error banners
            if viewModel.locationAuthorizationStatus == .denied || viewModel.locationAuthorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text(L10n.tr("map.permission.denied")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.crimson, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.isLocationReducedAccuracy {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.permission.reduced")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.amber, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.realLocationRestoredNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelocTheme.emerald)
                    Text(L10n.tr("map.restored.notice"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelocTheme.emerald)
                    Spacer()
                }
                .padding(10)
                .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let err = viewModel.snapshot.lastError {
                Text(L10n.format("map.last_error", err))
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            } else if viewModel.isInspectedLocationDistant,
                      viewModel.plannedRoutePoints.count >= 2,
                      let distMeters = viewModel.distanceFromRealLocationMeters {
                distantLocationWarningBanner(distMeters)
            }

            // Primary Action CTA
            HStack(spacing: 10) {
                if viewModel.isRouteSessionActive {
                    let isPaused = viewModel.trajectoryProgress?.isPaused ?? false
                    RelocPrimaryButton(
                        title: isPaused ? L10n.tr("route.button.resume") : L10n.tr("route.button.pause"),
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        gradient: isPaused ? RelocTheme.emeraldGradient : LinearGradient(colors: [RelocTheme.amber, Color(red: 0.85, green: 0.48, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    ) {
                        viewModel.toggleTrajectoryPause()
                    }
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.stop_restore"),
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: L10n.tr("route.button.start"),
                        systemImage: "play.fill",
                        gradient: RelocTheme.emeraldGradient,
                        disabled: !viewModel.canStartRouteSession
                    ) {
                        viewModel.startRouteSession()
                    }
                }
            }
        }
        .relocGlassCard(cornerRadius: 24, padding: 14)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {}
        }
    }

    private func routeMiniIconButton(_ systemName: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button {
            RelocTheme.hapticLight()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var defaultRouteSaveName: String {
        if let imported = viewModel.importedRouteTitle, !imported.isEmpty {
            return imported
        }
        if viewModel.isCurrentRouteFreehand {
            return "\(L10n.tr("route.creation.freehand")) \(RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))"
        }
        if let first = viewModel.routeWaypoints.first?.name,
           let last = viewModel.routeWaypoints.last?.name,
           first != last {
            return "\(first) → \(last)"
        }
        return "\(viewModel.routePreset.title) \(RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))"
    }

    private var routeGoalSummaryLabel: String {
        switch viewModel.routeStopGoalKind {
        case .none:
            return L10n.tr("route.goal.chip.none")
        case .distance:
            return L10n.format("route.goal.chip.distance", viewModel.routeTargetDistanceKm)
        case .laps:
            return L10n.format("route.goal.chip.laps", viewModel.routeTargetLaps)
        }
    }

    private var routeHeaderTitle: String {
        if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
            if prog.isCompleted {
                return L10n.tr("route.status.completed")
            } else if prog.isPaused {
                return L10n.tr("route.status.paused")
            } else if prog.isWaitingForStartLock {
                return prog.cumulativeTraveledMeters > 1.0
                    ? L10n.tr("route.status.waiting_relock")
                    : L10n.tr("route.status.waiting_lock")
            } else if prog.isBriefStopping {
                return L10n.tr("route.status.brief_stop")
            } else if let maxLaps = prog.targetLaps, viewModel.routeLoopMode != .once {
                return L10n.format("route.status.moving_lap_goal", prog.lapCount, maxLaps)
            } else if viewModel.routeLoopMode != .once {
                return L10n.format("route.status.moving_lap", prog.lapCount)
            } else {
                return L10n.tr("route.status.moving")
            }
        }
        if viewModel.isPlanningRoute {
            return L10n.tr("route.planning.calculating")
        }
        if viewModel.isFreehandDrawing {
            return L10n.tr("route.freehand.drawing_title")
        }
        if viewModel.isCurrentRouteFreehand {
            if viewModel.plannedRoutePoints.count >= 2 {
                if let imported = viewModel.importedRouteTitle, !imported.isEmpty {
                    return "\(imported) · \(RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))"
                }
                let key = viewModel.routeLoopMode == .loop
                    ? "route.freehand.ready_loop_title"
                    : "route.freehand.ready_title"
                return L10n.format(key, RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))
            }
            return L10n.tr("route.freehand.empty_title")
        }
        switch viewModel.routeWaypoints.count {
        case 0:
            return L10n.tr("route.planning.empty_title")
        case 1:
            return L10n.tr("route.planning.need_end_title")
        default:
            return L10n.format("route.planning.ready_title", RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))
        }
    }

    private var routeHeaderSubtitle: String {
        if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
            let pct = Int((prog.progress * 100).rounded())
            let speedForETA = max(prog.currentSpeedMps, viewModel.routeSpeedMps)
            if let goalDist = prog.targetTotalDistanceMeters, goalDist > 0 {
                let traveled = RouteGeometry.formatDistance(prog.cumulativeTraveledMeters)
                let target = RouteGeometry.formatDistance(goalDist)
                let rem = max(0, goalDist - prog.cumulativeTraveledMeters)
                let eta = prog.isCompleted ? L10n.tr("route.eta.done") : RouteGeometry.formatETA(seconds: rem / max(0.3, speedForETA))
                return "\(traveled) / \(target) · \(pct)% · ETA \(eta)"
            }
            let traveled = RouteGeometry.formatDistance(prog.traveledMeters)
            let total = RouteGeometry.formatDistance(prog.totalDistanceMeters)
            let remainingMeters = prog.isReversing ? prog.traveledMeters : max(0, prog.totalDistanceMeters - prog.traveledMeters)
            let eta = prog.isCompleted ? L10n.tr("route.eta.done") : RouteGeometry.formatETA(seconds: remainingMeters / max(0.3, speedForETA))
            return "\(traveled) / \(total) · \(pct)% · ETA \(eta)"
        }
        if viewModel.isFreehandDrawing {
            return L10n.tr("route.freehand.drawing_subtitle")
        }
        if viewModel.isCurrentRouteFreehand {
            if viewModel.plannedRoutePoints.count >= 2 {
                let eta = RouteGeometry.formatETA(seconds: viewModel.plannedRouteDistanceMeters / max(0.3, viewModel.routeSpeedMps))
                return L10n.format("route.freehand.ready_subtitle", viewModel.routeLoopMode.title, eta)
            }
            return L10n.tr("route.freehand.empty_subtitle")
        }
        switch viewModel.routeWaypoints.count {
        case 0:
            return L10n.tr("route.planning.empty_subtitle")
        case 1:
            return L10n.format("route.planning.start_selected", viewModel.routeWaypoints[0].name)
        default:
            let eta = RouteGeometry.formatETA(seconds: viewModel.plannedRouteDistanceMeters / max(0.3, viewModel.routeSpeedMps))
            return L10n.format("route.planning.ready_subtitle", viewModel.routeWaypoints.count, eta)
        }
    }

    private var configuredSpeedLabel: String {
        let mps = viewModel.routeSpeedMps
        let kmh = RouteGeometry.formatSpeedKmh(mps)
        if (viewModel.routePreset == .running || viewModel.routePreset == .walking),
           let pace = RouteGeometry.formatPacePerKm(mps) {
            return "\(kmh) · \(pace)"
        }
        return String(format: "%@ (%.1f m/s)", kmh, mps)
    }

    private func liveSpeedLabel(_ mps: Double) -> String {
        let kmh = RouteGeometry.formatSpeedKmh(mps)
        if (viewModel.routePreset == .running || viewModel.routePreset == .walking),
           let pace = RouteGeometry.formatPacePerKm(mps) {
            return "\(kmh) · \(pace)"
        }
        return kmh
    }

    @ViewBuilder
    private var restoreLocationStatusBanner: some View {
        if viewModel.needsRestoreLocationRefresh {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.restore.banner.stale"))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                Button {
                    RelocTheme.hapticMedium()
                    viewModel.launchOneTapRestoreRefresh()
                } label: {
                    Label(L10n.tr("map.restore.banner.button"), systemImage: "pip.enter")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RelocTheme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("map.restore.banner.working"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("map.restore.banner.refresh_now")) {
                    RelocTheme.hapticLight()
                    viewModel.launchOneTapRestoreRefresh()
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                .foregroundStyle(RelocTheme.accent)
            }
            .padding(9)
            .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    @ViewBuilder
    private var liveTriggerStatusBanner: some View {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(RelocTheme.emerald)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("map.live.confirmed.title"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RelocTheme.emerald)
                    Text(L10n.tr("map.live.confirmed.subtitle"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .injectingPendingLock where viewModel.needsLocationServiceRefresh,
             .waitingSubscription where viewModel.needsLocationServiceRefresh:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text(
                        viewModel.injectionPhase == .waitingSubscription
                            ? L10n.tr("map.live.waiting_sub.detail")
                            : (viewModel.isDistantFromRealLocation
                                ? L10n.tr("map.live.pending_lock.distant_detail")
                                : L10n.tr("map.live.pending_lock.detail"))
                    )
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 8) {
                    Button {
                        RelocTheme.hapticMedium()
                        viewModel.launchOneTapLocationRefresh()
                    } label: {
                        Label(L10n.tr("map.live.refresh_button"), systemImage: "pip.enter")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RelocTheme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    Button {
                        RelocTheme.hapticLight()
                        viewModel.retryAutoLock()
                    } label: {
                        Text(L10n.tr("common.retry"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    viewModel.injectionPhase == .connecting
                        ? L10n.tr("map.live.connecting")
                        : (viewModel.injectionPhase == .waitingSubscription
                            ? L10n.tr("map.live.waking_sub")
                            : L10n.tr("map.live.injecting"))
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                if viewModel.snapshot.authenticated {
                    Button(L10n.tr("map.live.force_refresh")) {
                        RelocTheme.hapticLight()
                        viewModel.launchOneTapLocationRefresh()
                    }
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(RelocTheme.accent)
                }
            }
            .padding(9)
            .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    // MARK: - Search Action

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        if isSearchFocused || hasSearchDropdown {
            dismissSearchOverlay()
            return
        }
        RelocTheme.hapticLight()
        if isRouteMode {
            guard !viewModel.isRouteSessionActive else { return }
            if viewModel.routeCreationMode == .freehand {
                return
            }
            viewModel.addRouteWaypoint(fromMapCoordinate: coord)
        } else if viewModel.isJoystickSessionActive {
            return
        } else {
            viewModel.selectLocationFromMap(coord)
        }
    }

    private func clearSearch() {
        activeSearch?.cancel()
        activeSearch = nil
        activeNominatimSearchTask?.cancel()
        activeNominatimSearchTask = nil
        isSearching = false
        searchText = ""
        searchResults = []
        searchStatusMessage = nil
        searchCompleter.clear()
    }

    private func dismissSearchOverlay() {
        isSearchFocused = false
        activeNominatimSearchTask?.cancel()
        activeNominatimSearchTask = nil
        searchStatusMessage = nil
        searchResults = []
        searchCompleter.clear()
    }

    static func formattedAddress(for item: MKMapItem) -> String? {
        if let title = item.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, title != item.name {
            return title
        }
        let parts = [
            item.placemark.administrativeArea,
            item.placemark.locality,
            item.placemark.subLocality,
            item.placemark.thoroughfare,
            item.placemark.subThoroughfare
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        let coord = item.placemark.coordinate
        return String(format: "%.5f, %.5f", coord.latitude, coord.longitude)
    }

    private func searchErrorDescription(for error: Error?) -> String {
        if let mkError = error as? MKError {
            switch mkError.code {
            case .placemarkNotFound:
                return L10n.tr("map.search.error.not_found")
            case .loadingThrottled:
                return L10n.tr("map.search.error.throttled")
            default:
                return L10n.tr("map.search.error.network")
            }
        }
        return error != nil ? L10n.tr("map.search.error.network") : L10n.tr("map.search.error.not_found")
    }

    private func parseCoordinateInput(_ input: String) -> (lat: Double, lon: Double, alt: Double?)? {
        let normalized = input.replacingOccurrences(of: "，", with: ",")
        let parts = normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3,
              let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite,
              (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            return nil
        }
        if parts.count == 3 {
            let altToken = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "mM "))
            guard let alt = Double(altToken), alt.isFinite, (-500.0...50_000.0).contains(alt) else {
                return nil
            }
            return (lat, lon, alt)
        }
        return (lat, lon, nil)
    }

    private func handleSearchTextChange(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchStatusMessage = nil
        if !searchResults.isEmpty {
            searchResults = []
        }
        guard !trimmed.isEmpty, parseCoordinateInput(trimmed) == nil else {
            searchCompleter.clear()
            return
        }
        searchCompleter.update(query: trimmed, region: currentSearchRegion)
    }

    private static func makePlaceSearchResult(from item: MKMapItem, index: Int) -> PlaceSearchResult {
        let coord = item.placemark.coordinate
        let title = item.name ?? L10n.tr("map.unknown_place")
        return PlaceSearchResult(
            id: "mk-\(index)-\(title)-\(coord.latitude)-\(coord.longitude)",
            name: title,
            address: formattedAddress(for: item),
            latitude: coord.latitude,
            longitude: coord.longitude,
            isoCountryCode: item.placemark.isoCountryCode,
            isPureWGS84: false,
            isOSMResult: false
        )
    }

    private func applyPlaceResultSelection(_ result: PlaceSearchResult) {
        RelocTheme.hapticLight()
        isSearchFocused = false
        activeSearch?.cancel()
        activeSearch = nil
        activeNominatimSearchTask?.cancel()
        activeNominatimSearchTask = nil
        isSearching = false
        searchStatusMessage = nil
        searchCompleter.clear()
        let coord = result.coordinate
        if isRouteMode && !viewModel.isRouteSessionActive {
            if viewModel.routeCreationMode == .freehand {
                let wgs: CLLocationCoordinate2D
                if !result.isPureWGS84 && viewModel.gcj02CorrectionEnabled && CoordinateTransform.shouldApplyGCJ02(
                    lat: coord.latitude,
                    lon: coord.longitude,
                    isoCountryCode: result.isoCountryCode
                ) {
                    wgs = CoordinateTransform.gcj02ToWGS84(lat: coord.latitude, lon: coord.longitude)
                } else {
                    wgs = coord
                }
                cameraTarget = viewModel.toMapCoordinate(wgs)
            } else {
                viewModel.addRouteWaypoint(
                    fromSearchCoordinate: coord,
                    isoCountryCode: result.isoCountryCode,
                    isPureWGS84: result.isPureWGS84,
                    name: result.name
                )
                if let last = viewModel.routeMapWaypointCoordinates.last {
                    cameraTarget = last
                }
            }
        } else {
            viewModel.selectSearchResultCoordinate(
                coord,
                isoCountryCode: result.isoCountryCode,
                isPureWGS84: result.isPureWGS84,
                name: result.name,
                address: result.address
            )
            cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
        }
        searchResults = []
        searchText = ""
    }

    private func selectSuggestion(_ suggestion: LocationSearchSuggestion) {
        switch suggestion {
        case .place(let result):
            applyPlaceResultSelection(result)
        case .completion(let completion, _):
            selectCompletion(completion)
        }
    }

    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        RelocTheme.hapticLight()
        isSearchFocused = false
        activeSearch?.cancel()
        activeNominatimSearchTask?.cancel()
        activeNominatimSearchTask = nil
        isSearching = true
        searchStatusMessage = nil
        searchResults = []
        searchCompleter.clear()

        let req = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: req)
        activeSearch = search
        let fallbackQuery = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: " ")
        let regionSnapshot = currentSearchRegion
        search.start { response, error in
            Task { @MainActor in
                guard activeSearch === search else { return }
                activeSearch = nil
                let items = response?.mapItems ?? []
                let mapped = items.enumerated().map { Self.makePlaceSearchResult(from: $1, index: $0) }
                if let first = mapped.first, mapped.count == 1 || !completion.subtitle.isEmpty {
                    isSearching = false
                    applyPlaceResultSelection(first)
                } else if !mapped.isEmpty {
                    isSearching = false
                    searchResults = mapped
                } else {
                    runNominatimFallbackSearch(query: fallbackQuery, region: regionSnapshot, originalError: error)
                }
            }
        }
    }

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchFocused = false
        searchStatusMessage = nil
        searchCompleter.clear()

        if let coord = parseCoordinateInput(trimmed) {
            if isRouteMode && !viewModel.isRouteSessionActive {
                let pt = RoutePoint(
                    latitude: coord.lat,
                    longitude: coord.lon,
                    altitude: coord.alt ?? viewModel.inspectedLocation.altitude
                )
                viewModel.addRouteWaypointWGS(pt, name: String(format: "%.5f, %.5f", coord.lat, coord.lon))
                if let last = viewModel.routeMapWaypointCoordinates.last {
                    cameraTarget = last
                }
            } else {
                let loc = TargetLocation(
                    latitude: coord.lat,
                    longitude: coord.lon,
                    altitude: coord.alt ?? viewModel.inspectedLocation.altitude
                )
                viewModel.selectWGSLocation(loc, resolveAltitude: coord.alt == nil)
                cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
            }
            searchResults = []
            searchText = ""
            return
        }

        activeSearch?.cancel()
        activeNominatimSearchTask?.cancel()
        activeNominatimSearchTask = nil
        isSearching = true
        let regionSnapshot = currentSearchRegion
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        req.region = regionSnapshot
        let search = MKLocalSearch(request: req)
        activeSearch = search
        search.start { response, error in
            Task { @MainActor in
                guard activeSearch === search else { return }
                activeSearch = nil
                let items = response?.mapItems ?? []
                let mapped = items.enumerated().map { Self.makePlaceSearchResult(from: $1, index: $0) }
                if !mapped.isEmpty {
                    isSearching = false
                    searchResults = mapped
                } else {
                    runNominatimFallbackSearch(query: trimmed, region: regionSnapshot, originalError: error)
                }
            }
        }
    }

    private func runNominatimFallbackSearch(query: String, region: MKCoordinateRegion, originalError: Error?) {
        activeNominatimSearchTask?.cancel()
        activeNominatimSearchTask = Task { @MainActor in
            let osmResults = await NominatimSearchClient.search(query: query, region: region, limit: 6)
            guard !Task.isCancelled else { return }
            isSearching = false
            if !osmResults.isEmpty {
                searchResults = osmResults
            } else {
                searchResults = []
                searchStatusMessage = searchErrorDescription(for: originalError)
            }
        }
    }
}

// MARK: - Live Viewport-Scoped Location Search Completer

private enum LocationSearchSuggestion: Identifiable {
    case completion(MKLocalSearchCompletion, Int)
    case place(PlaceSearchResult)

    var id: String {
        switch self {
        case .completion(let c, let idx):
            return "c-\(idx)-\(c.title)-\(c.subtitle)"
        case .place(let p):
            return p.id
        }
    }

    var isDirectMapItem: Bool {
        if case .place = self { return true }
        return false
    }

    var isOSMResult: Bool {
        if case .place(let p) = self { return p.isOSMResult }
        return false
    }

    var title: String {
        switch self {
        case .completion(let c, _): return c.title
        case .place(let p): return p.name
        }
    }

    var subtitle: String? {
        switch self {
        case .completion(let c, _):
            let trimmed = c.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .place(let p):
            return p.address
        }
    }
}

@MainActor
private final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [LocationSearchSuggestion] = []

    private let completer = MKLocalSearchCompleter()
    private var debounceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var nominatimFallbackTask: Task<Void, Never>?
    private var fallbackSearch: MKLocalSearch?
    private var activeQuery = ""
    private var activeRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.334606, longitude: -122.009102),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )
    private var completerRespondedForActiveQuery = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, region: MKCoordinateRegion) {
        debounceTask?.cancel()
        fallbackTask?.cancel()
        nominatimFallbackTask?.cancel()
        nominatimFallbackTask = nil
        fallbackSearch?.cancel()
        fallbackSearch = nil

        activeQuery = query
        activeRegion = region
        completerRespondedForActiveQuery = false

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.activeQuery == query else { return }
            self.completer.region = region
            self.completer.queryFragment = query
            self.scheduleFallbackSearch(for: query, region: region, delayNanoseconds: 420_000_000)
        }
    }

    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        nominatimFallbackTask?.cancel()
        nominatimFallbackTask = nil
        fallbackSearch?.cancel()
        fallbackSearch = nil
        activeQuery = ""
        completerRespondedForActiveQuery = false
        if !completer.queryFragment.isEmpty {
            completer.queryFragment = ""
        }
        if !suggestions.isEmpty {
            suggestions = []
        }
    }

    private func scheduleFallbackSearch(for query: String, region: MKCoordinateRegion, delayNanoseconds: UInt64) {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self, self.activeQuery == query else { return }
            if self.completerRespondedForActiveQuery && !self.suggestions.isEmpty {
                return
            }
            self.runFallbackLocalSearch(query: query, region: region)
        }
    }

    private func runFallbackLocalSearch(query: String, region: MKCoordinateRegion) {
        fallbackSearch?.cancel()
        nominatimFallbackTask?.cancel()
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = region
        let search = MKLocalSearch(request: req)
        fallbackSearch = search
        search.start { [weak self] response, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.fallbackSearch === search,
                      self.activeQuery == query else { return }
                self.fallbackSearch = nil
                guard !(self.completerRespondedForActiveQuery && !self.suggestions.isEmpty) else { return }
                let items = response?.mapItems ?? []
                if !items.isEmpty {
                    self.suggestions = items.prefix(6).enumerated().map { idx, item in
                        let coord = item.placemark.coordinate
                        let title = item.name ?? L10n.tr("map.unknown_place")
                        return .place(PlaceSearchResult(
                            id: "mk-fb-\(idx)-\(title)-\(coord.latitude)-\(coord.longitude)",
                            name: title,
                            address: MapPickerView.formattedAddress(for: item),
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            isoCountryCode: item.placemark.isoCountryCode,
                            isPureWGS84: false,
                            isOSMResult: false
                        ))
                    }
                } else {
                    self.runNominatimFallback(query: query, region: region)
                }
            }
        }
    }

    private func runNominatimFallback(query: String, region: MKCoordinateRegion) {
        nominatimFallbackTask?.cancel()
        nominatimFallbackTask = Task { [weak self] in
            let osmResults = await NominatimSearchClient.search(query: query, region: region, limit: 6)
            guard !Task.isCancelled, let self, self.activeQuery == query else { return }
            guard !(self.completerRespondedForActiveQuery && !self.suggestions.isEmpty) else { return }
            if !osmResults.isEmpty {
                self.suggestions = osmResults.map { .place($0) }
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        let fragment = completer.queryFragment
        Task { @MainActor [weak self] in
            guard let self, !self.activeQuery.isEmpty, fragment == self.activeQuery else { return }
            if !results.isEmpty {
                self.completerRespondedForActiveQuery = true
                self.fallbackTask?.cancel()
                self.nominatimFallbackTask?.cancel()
                self.nominatimFallbackTask = nil
                self.fallbackSearch?.cancel()
                self.fallbackSearch = nil
                self.suggestions = results.prefix(6).enumerated().map { .completion($1, $0) }
            } else {
                self.scheduleFallbackSearch(for: self.activeQuery, region: self.activeRegion, delayNanoseconds: 0)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let fragment = completer.queryFragment
        Task { @MainActor [weak self] in
            guard let self, !self.activeQuery.isEmpty, fragment == self.activeQuery else { return }
            self.scheduleFallbackSearch(for: self.activeQuery, region: self.activeRegion, delayNanoseconds: 0)
        }
    }
}

// MARK: - Interactive MKMapView Wrapper

private final class MKFreehandHostView: UIView {
    let mapView = MKMapView(frame: .zero)
    let freehandOverlay = FreehandDrawingOverlayView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        freehandOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(mapView)
        addSubview(freehandOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        freehandOverlay.frame = bounds
    }
}

private struct InteractiveMKMapView: UIViewRepresentable {
    let activeCoordinate: CLLocationCoordinate2D
    let isSessionRunning: Bool
    let pendingCoordinate: CLLocationCoordinate2D?
    var routePolyline: [CLLocationCoordinate2D] = []
    var routeWaypoints: [CLLocationCoordinate2D] = []
    var showActivePin: Bool = true
    var isFreehandDrawing: Bool = false
    var canDragRouteWaypoints: Bool = false
    let mapStyle: MapDisplayStyle
    @Binding var cameraTarget: CLLocationCoordinate2D?
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil
    var onFinishFreehandStroke: (([CLLocationCoordinate2D]) -> Void)? = nil
    var onMoveRouteWaypoint: ((Int, CLLocationCoordinate2D) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTapCoordinate: onTapCoordinate,
            onRegionChange: onRegionChange,
            onFinishFreehandStroke: onFinishFreehandStroke,
            onMoveRouteWaypoint: onMoveRouteWaypoint
        )
    }

    func makeUIView(context: Context) -> MKFreehandHostView {
        let host = MKFreehandHostView(frame: .zero)
        let mapView = host.mapView
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let doubleTap = UITapGestureRecognizer(target: nil, action: nil)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = context.coordinator
        context.coordinator.doubleTapRecognizer = doubleTap
        mapView.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.require(toFail: doubleTap)
        context.coordinator.singleTapRecognizer = tap
        mapView.addGestureRecognizer(tap)

        context.coordinator.bindFreehandOverlay(host.freehandOverlay, mapView: mapView)
        context.coordinator.updateFreehandDrawing(isFreehandDrawing, on: host)

        applyMapStyle(to: mapView)

        if showActivePin {
            let activeAnn = TaggedAnnotation(kind: .active)
            activeAnn.coordinate = activeCoordinate
            activeAnn.title = L10n.tr("map.pin.active")
            mapView.addAnnotation(activeAnn)
            context.coordinator.activeAnnotation = activeAnn
        }

        context.coordinator.syncRoute(on: mapView, polyline: routePolyline, waypoints: routeWaypoints, isRunning: isSessionRunning)

        let region = MKCoordinateRegion(
            center: activeCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapView.setRegion(region, animated: false)
        if let onRegionChange {
            DispatchQueue.main.async {
                onRegionChange(region)
            }
        }
        return host
    }

    func updateUIView(_ uiView: MKFreehandHostView, context: Context) {
        let mapView = uiView.mapView
        context.coordinator.onTapCoordinate = onTapCoordinate
        context.coordinator.onRegionChange = onRegionChange
        context.coordinator.onFinishFreehandStroke = onFinishFreehandStroke
        context.coordinator.onMoveRouteWaypoint = onMoveRouteWaypoint
        context.coordinator.isSessionRunning = isSessionRunning
        let dragChanged = context.coordinator.canDragRouteWaypoints != canDragRouteWaypoints
        context.coordinator.canDragRouteWaypoints = canDragRouteWaypoints
        if dragChanged {
            for ann in context.coordinator.routeWaypointAnnotations {
                mapView.view(for: ann)?.isDraggable = canDragRouteWaypoints
            }
        }
        context.coordinator.updateFreehandDrawing(isFreehandDrawing, on: uiView)

        applyMapStyle(to: mapView)

        if showActivePin {
            if let activeAnn = context.coordinator.activeAnnotation {
                let activeTitle = L10n.tr("map.pin.active")
                if activeAnn.title != activeTitle {
                    activeAnn.title = activeTitle
                }
                if abs(activeAnn.coordinate.latitude - activeCoordinate.latitude) > 1e-9 ||
                   abs(activeAnn.coordinate.longitude - activeCoordinate.longitude) > 1e-9 {
                    activeAnn.coordinate = activeCoordinate
                }
                if let markerView = mapView.view(for: activeAnn) as? MKMarkerAnnotationView {
                    markerView.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                }
            } else {
                let activeAnn = TaggedAnnotation(kind: .active)
                activeAnn.coordinate = activeCoordinate
                activeAnn.title = L10n.tr("map.pin.active")
                mapView.addAnnotation(activeAnn)
                context.coordinator.activeAnnotation = activeAnn
            }
        } else if let activeAnn = context.coordinator.activeAnnotation {
            mapView.removeAnnotation(activeAnn)
            context.coordinator.activeAnnotation = nil
        }

        if let pending = pendingCoordinate {
            let pendingTitle = L10n.tr("map.pin.pending")
            if let existing = context.coordinator.pendingAnnotation {
                if existing.title != pendingTitle {
                    existing.title = pendingTitle
                }
                existing.coordinate = pending
            } else {
                let ann = TaggedAnnotation(kind: .pending)
                ann.coordinate = pending
                ann.title = pendingTitle
                mapView.addAnnotation(ann)
                context.coordinator.pendingAnnotation = ann
            }
        } else if let existing = context.coordinator.pendingAnnotation {
            mapView.removeAnnotation(existing)
            context.coordinator.pendingAnnotation = nil
        }

        context.coordinator.syncRoute(on: mapView, polyline: routePolyline, waypoints: routeWaypoints, isRunning: isSessionRunning)

        if let target = cameraTarget {
            let region = MKCoordinateRegion(
                center: target,
                span: mapView.region.span.latitudeDelta > 0.25
                    ? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    : mapView.region.span
            )
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                cameraTarget = nil
            }
        }
    }

    private func applyMapStyle(to mapView: MKMapView) {
        switch mapStyle {
        case .standard: mapView.mapType = .standard
        case .satellite: mapView.mapType = .satellite
        case .hybrid: mapView.mapType = .hybrid
        }
    }

    final class TaggedAnnotation: MKPointAnnotation {
        enum Kind { case active, pending }
        let kind: Kind
        init(kind: Kind) {
            self.kind = kind
            super.init()
        }
    }

    final class RoutePinAnnotation: MKPointAnnotation {
        enum Role {
            case start
            case via(Int)
            case end
        }
        let role: Role
        let index: Int
        init(role: Role, index: Int) {
            self.role = role
            self.index = index
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onTapCoordinate: (CLLocationCoordinate2D) -> Void
        var onRegionChange: ((MKCoordinateRegion) -> Void)?
        var onFinishFreehandStroke: (([CLLocationCoordinate2D]) -> Void)?
        var onMoveRouteWaypoint: ((Int, CLLocationCoordinate2D) -> Void)?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        weak var singleTapRecognizer: UITapGestureRecognizer?
        var isSessionRunning = false
        var canDragRouteWaypoints = false
        var activeAnnotation: TaggedAnnotation?
        var pendingAnnotation: TaggedAnnotation?
        var routeOverlay: MKPolyline?
        var routeWaypointAnnotations: [RoutePinAnnotation] = []
        var lastPolylineSignature = ""
        var lastWaypointsSignature = ""
        var lastRunningColorState = false

        private var twoFingerStartRect: MKMapRect?
        private var twoFingerAnchorPoint: MKMapPoint?
        private var twoFingerPanActive = false
        private var twoFingerPinchActive = false
        private var twoFingerScale: Double = 1.0
        private var twoFingerMidPoint: CGPoint = .zero

        init(
            onTapCoordinate: @escaping (CLLocationCoordinate2D) -> Void,
            onRegionChange: ((MKCoordinateRegion) -> Void)?,
            onFinishFreehandStroke: (([CLLocationCoordinate2D]) -> Void)?,
            onMoveRouteWaypoint: ((Int, CLLocationCoordinate2D) -> Void)?
        ) {
            self.onTapCoordinate = onTapCoordinate
            self.onRegionChange = onRegionChange
            self.onFinishFreehandStroke = onFinishFreehandStroke
            self.onMoveRouteWaypoint = onMoveRouteWaypoint
        }

        private func resetTwoFingerAnchor(on mapView: MKMapView, midPoint: CGPoint) {
            twoFingerStartRect = mapView.visibleMapRect
            twoFingerAnchorPoint = MKMapPoint(mapView.convert(midPoint, toCoordinateFrom: mapView))
            twoFingerMidPoint = midPoint
            twoFingerScale = 1.0
        }

        private func applyTwoFingerCameraTransform(on mapView: MKMapView) {
            guard let startRect = twoFingerStartRect,
                  let anchor = twoFingerAnchorPoint,
                  mapView.bounds.width > 1,
                  mapView.bounds.height > 1 else { return }

            let worldW = MKMapSize.world.width
            let worldH = MKMapSize.world.height
            let aspect = startRect.size.height / max(1.0, startRect.size.width)
            let targetW = min(worldW * 0.9, max(400.0, startRect.size.width / max(0.05, twoFingerScale)))
            let targetH = min(worldH * 0.9, max(400.0, targetW * aspect))

            let normX = Double(twoFingerMidPoint.x / mapView.bounds.width)
            let normY = Double(twoFingerMidPoint.y / mapView.bounds.height)
            var originX = anchor.x - normX * targetW
            if originX < 0 { originX += worldW }
            if originX >= worldW { originX = originX.truncatingRemainder(dividingBy: worldW) }
            let rawOriginY = anchor.y - normY * targetH
            let originY = min(max(0.0, rawOriginY), max(0.0, worldH - targetH))

            mapView.setVisibleMapRect(
                MKMapRect(x: originX, y: originY, width: targetW, height: targetH),
                animated: false
            )
        }

        func bindFreehandOverlay(_ overlay: FreehandDrawingOverlayView, mapView: MKMapView) {
            overlay.convertPointToCoordinate = { [weak mapView] pt in
                guard let mapView else { return kCLLocationCoordinate2DInvalid }
                return mapView.convert(pt, toCoordinateFrom: mapView)
            }
            overlay.onFinishStroke = { [weak self] coords in
                self?.onFinishFreehandStroke?(coords)
            }
            overlay.onTwoFingerPan = { [weak self, weak mapView] gesture in
                guard let self, let mapView, mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }
                let mid = gesture.location(in: mapView)
                switch gesture.state {
                case .began:
                    let wasIdle = !self.twoFingerPanActive && !self.twoFingerPinchActive
                    self.twoFingerPanActive = true
                    if wasIdle {
                        self.resetTwoFingerAnchor(on: mapView, midPoint: mid)
                    }
                case .changed:
                    guard gesture.numberOfTouches >= 2 else { return }
                    if self.twoFingerStartRect == nil {
                        self.resetTwoFingerAnchor(on: mapView, midPoint: mid)
                    }
                    self.twoFingerMidPoint = mid
                    self.applyTwoFingerCameraTransform(on: mapView)
                case .ended, .cancelled, .failed:
                    self.twoFingerPanActive = false
                    if !self.twoFingerPinchActive {
                        self.twoFingerStartRect = nil
                        self.twoFingerAnchorPoint = nil
                        self.twoFingerScale = 1.0
                    } else {
                        self.resetTwoFingerAnchor(on: mapView, midPoint: mid)
                    }
                default:
                    break
                }
            }
            overlay.onTwoFingerPinch = { [weak self, weak mapView] gesture in
                guard let self, let mapView, mapView.bounds.width > 1, mapView.bounds.height > 1, gesture.scale > 0.05 else { return }
                let mid = gesture.location(in: mapView)
                switch gesture.state {
                case .began:
                    let wasIdle = !self.twoFingerPanActive && !self.twoFingerPinchActive
                    self.twoFingerPinchActive = true
                    if wasIdle {
                        self.resetTwoFingerAnchor(on: mapView, midPoint: mid)
                    }
                    self.twoFingerScale = Double(gesture.scale)
                case .changed:
                    guard gesture.numberOfTouches >= 2 else { return }
                    if self.twoFingerStartRect == nil {
                        self.resetTwoFingerAnchor(on: mapView, midPoint: mid)
                    }
                    self.twoFingerScale = Double(gesture.scale)
                    self.twoFingerMidPoint = mid
                    self.applyTwoFingerCameraTransform(on: mapView)
                case .ended, .cancelled, .failed:
                    self.twoFingerPinchActive = false
                    if !self.twoFingerPanActive {
                        self.twoFingerStartRect = nil
                        self.twoFingerAnchorPoint = nil
                        self.twoFingerScale = 1.0
                    } else {
                        self.resetTwoFingerAnchor(on: mapView, midPoint: mid)
                    }
                default:
                    break
                }
            }
        }

        func updateFreehandDrawing(_ enabled: Bool, on host: MKFreehandHostView) {
            let mapView = host.mapView
            host.freehandOverlay.isDrawingEnabled = enabled
            if mapView.isScrollEnabled == enabled {
                mapView.isScrollEnabled = !enabled
            }
            if mapView.isZoomEnabled == enabled {
                mapView.isZoomEnabled = !enabled
            }
            if mapView.isRotateEnabled == enabled {
                mapView.isRotateEnabled = !enabled
            }
            if mapView.isPitchEnabled == enabled {
                mapView.isPitchEnabled = !enabled
            }
            singleTapRecognizer?.isEnabled = !enabled
            doubleTapRecognizer?.isEnabled = !enabled
        }

        func syncRoute(
            on mapView: MKMapView,
            polyline: [CLLocationCoordinate2D],
            waypoints: [CLLocationCoordinate2D],
            isRunning: Bool
        ) {
            let polySig: String
            if let first = polyline.first, let last = polyline.last {
                let mid = polyline[polyline.count / 2]
                polySig = "\(polyline.count):\(String(format: "%.5f,%.5f", first.latitude, first.longitude)):\(String(format: "%.5f,%.5f", mid.latitude, mid.longitude)):\(String(format: "%.5f,%.5f", last.latitude, last.longitude))"
            } else {
                polySig = ""
            }
            if polySig != lastPolylineSignature || lastRunningColorState != isRunning {
                lastPolylineSignature = polySig
                lastRunningColorState = isRunning
                if let existing = routeOverlay {
                    mapView.removeOverlay(existing)
                    routeOverlay = nil
                }
                if polyline.count >= 2 {
                    let overlay = MKPolyline(coordinates: polyline, count: polyline.count)
                    mapView.addOverlay(overlay, level: .aboveRoads)
                    routeOverlay = overlay
                }
            }

            let wpSig = waypoints.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ";")
            if wpSig != lastWaypointsSignature {
                lastWaypointsSignature = wpSig
                if !routeWaypointAnnotations.isEmpty {
                    mapView.removeAnnotations(routeWaypointAnnotations)
                    routeWaypointAnnotations.removeAll()
                }
                for (idx, coord) in waypoints.enumerated() {
                    let role: RoutePinAnnotation.Role
                    let title: String
                    if idx == 0 {
                        role = .start
                        title = L10n.tr("route.pin.start")
                    } else if idx == waypoints.count - 1 {
                        role = .end
                        title = L10n.tr("route.pin.end")
                    } else {
                        role = .via(idx)
                        title = L10n.format("route.pin.via", idx)
                    }
                    let ann = RoutePinAnnotation(role: role, index: idx)
                    ann.coordinate = coord
                    ann.title = title
                    routeWaypointAnnotations.append(ann)
                }
                if !routeWaypointAnnotations.isEmpty {
                    mapView.addAnnotations(routeWaypointAnnotations)
                }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Allow MKMapView's native double-tap zoom to fire alongside our guard recognizer
            // so single-tap pin placement is suppressed on double-tap zoom.
            gestureRecognizer === doubleTapRecognizer || otherGestureRecognizer === doubleTapRecognizer
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapCoordinate(coord)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in
                self?.onRegionChange?(region)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                renderer.lineWidth = 5.5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let routePin = annotation as? RoutePinAnnotation {
                let id = "reloc.route.pin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.displayPriority = .required
                view.isDraggable = canDragRouteWaypoints
                switch routePin.role {
                case .start:
                    view.markerTintColor = UIColor(RelocTheme.emerald)
                    view.glyphText = nil
                    view.glyphImage = UIImage(systemName: "flag.fill")
                case .end:
                    view.markerTintColor = UIColor(RelocTheme.crimson)
                    view.glyphText = nil
                    view.glyphImage = UIImage(systemName: "flag.checkered")
                case .via(let number):
                    view.markerTintColor = UIColor(RelocTheme.accent)
                    view.glyphImage = nil
                    view.glyphText = "\(number)"
                }
                return view
            }
            guard let tagged = annotation as? TaggedAnnotation else { return nil }
            let id = tagged.kind == .active ? "reloc.active" : "reloc.pending"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.displayPriority = .required
            if tagged.kind == .active {
                view.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                view.glyphImage = UIImage(systemName: "location.fill")
            } else {
                view.markerTintColor = UIColor(RelocTheme.amber)
                view.glyphImage = UIImage(systemName: "mappin")
            }
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            guard let routePin = view.annotation as? RoutePinAnnotation else { return }
            if newState == .ending {
                view.setDragState(.none, animated: true)
                onMoveRouteWaypoint?(routePin.index, routePin.coordinate)
            } else if newState == .canceling {
                view.setDragState(.none, animated: true)
            }
        }
    }
}

// MARK: - Route Goal Sheet (Target Distance / Target Laps / Brief Stops)

private struct RouteGoalSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    @Environment(\.dismiss) private var dismiss

    private let distancePresets: [Double] = [1.0, 2.0, 3.0, 5.0, 10.0]
    private let lapPresets: [Int] = [2, 3, 5, 8, 10]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.tr("route.goal.mode.label"), selection: $viewModel.routeStopGoalKind) {
                        ForEach(RouteStopGoalKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L10n.tr("route.goal.section.header"))
                } footer: {
                    Text(L10n.tr("route.goal.section.footer"))
                }

                if viewModel.routeStopGoalKind == .distance {
                    Section(L10n.tr("route.goal.distance.header")) {
                        Stepper(
                            value: $viewModel.routeTargetDistanceKm,
                            in: 0.2...100.0,
                            step: 0.2
                        ) {
                            Text(L10n.format("route.goal.distance.value", viewModel.routeTargetDistanceKm))
                                .monospacedDigit()
                                .font(.headline)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(distancePresets, id: \.self) { km in
                                    let selected = abs(viewModel.routeTargetDistanceKm - km) < 0.05
                                    Button {
                                        RelocTheme.hapticLight()
                                        viewModel.routeTargetDistanceKm = km
                                    } label: {
                                        Text(String(format: "%.0f km", km))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(selected ? RelocTheme.accent : Color.secondary.opacity(0.14), in: Capsule())
                                            .foregroundStyle(selected ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else if viewModel.routeStopGoalKind == .laps {
                    Section {
                        Stepper(value: $viewModel.routeTargetLaps, in: 1...100, step: 1) {
                            Text(L10n.format("route.goal.laps.value", viewModel.routeTargetLaps))
                                .monospacedDigit()
                                .font(.headline)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(lapPresets, id: \.self) { laps in
                                    let selected = viewModel.routeTargetLaps == laps
                                    Button {
                                        RelocTheme.hapticLight()
                                        viewModel.routeTargetLaps = laps
                                    } label: {
                                        Text(L10n.format("route.goal.laps.short", laps))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(selected ? RelocTheme.accent : Color.secondary.opacity(0.14), in: Capsule())
                                            .foregroundStyle(selected ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(L10n.tr("route.goal.laps.header"))
                    } footer: {
                        if viewModel.routeLoopMode == .once {
                            Text(L10n.tr("route.goal.laps.once_hint"))
                                .foregroundStyle(RelocTheme.amber)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $viewModel.routeBriefStopsEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("route.brief_stops.title"))
                                Text(L10n.tr("route.brief_stops.subtitle"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            SettingsIconBadge(systemName: "pause.circle.fill", color: RelocTheme.amber)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("route.goal.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.ok")) { dismiss() }
                }
            }
        }
    }
}

private enum ManualCoordinateDatum: String, CaseIterable, Identifiable {
    case wgs84
    case gcj02

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wgs84: return L10n.tr("manual.datum.wgs84")
        case .gcj02: return L10n.tr("manual.datum.gcj02")
        }
    }
}

private struct ManualCoordinateSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onApply: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var datum: ManualCoordinateDatum = .wgs84
    @State private var latText = ""
    @State private var lonText = ""
    @State private var altText = ""
    @State private var favoriteName = ""

    private var parsedCoordinate: (lat: Double, lon: Double, alt: Double, autoAltitude: Bool)? {
        guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
              lat.isFinite, lon.isFinite,
              (-90.0...90.0).contains(lat),
              (-180.0...180.0).contains(lon) else {
            return nil
        }
        let trimmedAlt = altText.trimmingCharacters(in: .whitespaces)
        if trimmedAlt.isEmpty {
            return (lat, lon, viewModel.inspectedLocation.altitude, true)
        }
        guard let alt = Double(trimmedAlt), alt.isFinite, (-500.0...50_000.0).contains(alt) else {
            return nil
        }
        return (lat, lon, alt, false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.tr("manual.datum.label"), selection: $datum) {
                        ForEach(ManualCoordinateDatum.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField(L10n.tr("manual.lat.placeholder"), text: $latText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(L10n.tr("manual.lon.placeholder"), text: $lonText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(L10n.tr("manual.alt.placeholder"), text: $altText)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text(L10n.tr("manual.section.header"))
                } footer: {
                    if parsedCoordinate == nil {
                        Text(L10n.tr("manual.footer.invalid"))
                            .foregroundStyle(RelocTheme.crimson)
                    } else if datum == .gcj02 {
                        Text(L10n.tr("manual.footer.gcj02_hint"))
                    } else {
                        Text(L10n.tr("manual.footer.hint"))
                    }
                }

                Section(L10n.tr("manual.favorite.header")) {
                    TextField(L10n.tr("manual.favorite.placeholder"), text: $favoriteName)
                }
            }
            .navigationTitle(L10n.tr("manual.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.apply")) {
                        guard let parsed = parsedCoordinate else { return }
                        let wgs: CLLocationCoordinate2D = datum == .gcj02
                            ? CoordinateTransform.gcj02ToWGS84(lat: parsed.lat, lon: parsed.lon)
                            : CLLocationCoordinate2D(latitude: parsed.lat, longitude: parsed.lon)
                        let trimmedName = favoriteName.trimmingCharacters(in: .whitespaces)
                        viewModel.selectWGSLocation(
                            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: parsed.alt),
                            name: trimmedName.isEmpty ? nil : trimmedName,
                            resolveAltitude: parsed.autoAltitude
                        )
                        if !trimmedName.isEmpty {
                            viewModel.saveCurrentAsFavorite(name: trimmedName)
                        }
                        onApply(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                        dismiss()
                    }
                    .disabled(parsedCoordinate == nil)
                }
            }
            .relocOnChange(of: datum) { newDatum in
                guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
                      let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
                      lat.isFinite, lon.isFinite,
                      (-90.0...90.0).contains(lat),
                      (-180.0...180.0).contains(lon) else { return }
                let converted: CLLocationCoordinate2D = newDatum == .gcj02
                    ? CoordinateTransform.wgs84ToGCJ02(lat: lat, lon: lon)
                    : CoordinateTransform.gcj02ToWGS84(lat: lat, lon: lon)
                latText = String(format: "%.6f", converted.latitude)
                lonText = String(format: "%.6f", converted.longitude)
            }
            .onAppear {
                datum = .wgs84
                let loc = viewModel.inspectedLocation
                latText = String(format: "%.6f", loc.latitude)
                lonText = String(format: "%.6f", loc.longitude)
                altText = String(format: "%.1f", loc.altitude)
            }
        }
    }
}

struct SharedFileItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
