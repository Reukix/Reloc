import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @ObservedObject var viewModel: RelocViewModel
    @ObservedObject private var coreLocation: LiveCoreLocationMonitor
    @Environment(\.colorScheme) private var colorScheme
    let switchToConfig: () -> Void

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool
    @State private var cameraTarget: CLLocationCoordinate2D?
    @State private var showManualCoordinate = false
    @State private var showPlacesSheet = false
    @State private var showStopConfirm = false
    @State private var copiedAddressToast = false

    init(viewModel: RelocViewModel, switchToConfig: @escaping () -> Void) {
        self.viewModel = viewModel
        self._coreLocation = ObservedObject(wrappedValue: viewModel.coreLocation)
        self.switchToConfig = switchToConfig
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.mapSource.isPureWGS84 {
                WebMercatorMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: viewModel.pendingMapCoordinate,
                    mapSource: viewModel.mapSource,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        isSearchFocused = false
                        RelocTheme.hapticLight()
                        viewModel.selectLocationFromMap(coord)
                    }
                )
                .ignoresSafeArea()
            } else {
                InteractiveMKMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: viewModel.pendingMapCoordinate,
                    mapSource: viewModel.mapSource,
                    mapStyle: viewModel.mapStyle,
                    isDarkMode: colorScheme == .dark,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        isSearchFocused = false
                        RelocTheme.hapticLight()
                        viewModel.selectLocationFromMap(coord)
                    }
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    rightControlDock
                }

                fixedLocationCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 10) {
                searchBar
                if !searchResults.isEmpty {
                    searchResultsList
                } else {
                    topStatusRow

                    if let interrupted = viewModel.interruptedSession, !viewModel.snapshot.isRunning {
                        interruptedRecoveryBanner(interrupted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbarBackground(.hidden, for: .tabBar)
        .sheet(isPresented: $showManualCoordinate) {
            ManualCoordinateSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .sheet(isPresented: $showPlacesSheet) {
            PlacesSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .confirmationDialog("停止定位并恢复真实位置？", isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button("停止并恢复", role: .destructive) {
                RelocTheme.hapticMedium()
                viewModel.stopAndRestore()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("停止后系统将逐步切回本机真实 GPS 位置。")
        }
    }

    // MARK: - Top Search Bar & Status Row

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RelocTheme.accent)

            TextField("搜索地点或输入 纬度, 经度", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit { performSearch() }

            Group {
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        RelocTheme.hapticLight()
                        isSearchFocused = false
                        showManualCoordinate = true
                    } label: {
                        Image(systemName: "number.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("手动输入坐标")
                }
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var topStatusRow: some View {
        HStack(spacing: 8) {
            Button(action: switchToConfig) {
                HStack(spacing: 7) {
                    PulsingStatusDot(
                        color: statusDotColor,
                        isPulsing: viewModel.snapshot.isRunning
                    )
                    Text(statusPillTitle)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            }

            Spacer()

            if viewModel.snapshot.isRunning {
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.emerald)
                    Text(String(format: "%.4f, %.4f", viewModel.targetLocation.latitude, viewModel.targetLocation.longitude))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
            }
        }
    }

    private var rightControlDock: some View {
        VStack(spacing: 10) {
            MapHUDIconButton(systemName: "bookmark.fill") {
                showPlacesSheet = true
            }

            Menu {
                Section("地图数据源") {
                    ForEach(MapSource.allCases) { source in
                        Button {
                            viewModel.mapSource = source
                        } label: {
                            Label(source.shortTitle, systemImage: viewModel.mapSource == source ? "checkmark" : "globe")
                        }
                    }
                }
                if viewModel.mapSource == .appleNative {
                    Section("Apple 地图样式") {
                        ForEach(MapDisplayStyle.allCases) { style in
                            Button {
                                viewModel.mapStyle = style
                            } label: {
                                Label(style.title, systemImage: viewModel.mapStyle == style ? "checkmark" : "map")
                            }
                        }
                    }
                }
                Section("坐标") {
                    Button { showManualCoordinate = true } label: {
                        Label("手动输入经纬度", systemImage: "number")
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            }

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

    private var statusDotColor: Color {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return RelocTheme.emerald
        case .injectingPendingLock, .waitingSubscription:
            return viewModel.needsLocationServiceRefresh ? RelocTheme.amber : RelocTheme.accent
        case .connecting:
            return RelocTheme.amber
        case .idle:
            if viewModel.connectionVerified { return RelocTheme.emerald }
            return viewModel.pairingStatus.isLoaded ? RelocTheme.accent : RelocTheme.crimson
        }
    }

    private var statusPillTitle: String {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return "外设定位已生效 ✓"
        case .injectingPendingLock:
            return viewModel.needsLocationServiceRefresh
                ? "待刷新生效 · ACK \(viewModel.snapshot.packetsAcknowledged)"
                : "切换定位中 · ACK \(viewModel.snapshot.packetsAcknowledged)"
        case .waitingSubscription:
            return "已鉴权 · 唤醒订阅中…"
        case .connecting:
            return "建立回环连接中…"
        case .idle:
            if viewModel.connectionVerified { return "回环已就绪" }
            return viewModel.pairingStatus.isLoaded ? "已配对 · 可一键定位" : "未配对设备"
        }
    }

    private var searchResultsContent: some View {
        let items = Array(searchResults.prefix(6).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.offset) { index, item in
                Button {
                    RelocTheme.hapticLight()
                    isSearchFocused = false
                    let coord = item.placemark.coordinate
                    viewModel.selectSearchResultCoordinate(coord, name: item.name, address: item.placemark.title)
                    cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
                    searchResults = []
                    searchText = ""
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(RelocTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "未知地点")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let title = item.placemark.title {
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                if index < items.count - 1 {
                    Divider().padding(.leading, 40)
                }
            }
        }
    }

    private var searchResultsList: some View {
        ViewThatFits(in: .vertical) {
            searchResultsContent
            ScrollView {
                searchResultsContent
            }
        }
        .frame(maxHeight: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private func interruptedRecoveryBanner(_ record: InterruptedSessionRecord) -> some View {
        HStack(spacing: 10) {
            SettingsIconBadge(systemName: "arrow.counterclockwise", color: RelocTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("上次定位会话意外中断")
                    .font(.caption.weight(.bold))
                Text("恢复上次位置：\(record.placeName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("恢复") {
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
                    .foregroundStyle(.secondary)
            }
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

                VStack(alignment: .leading, spacing: 2) {
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
                            let text = "\(viewModel.selectedPlaceName) (\(String(format: "%.6f, %.6f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude)))"
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

            if !viewModel.pairingStatus.isLoaded {
                Button(action: switchToConfig) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RelocTheme.amber)
                        Text("尚未配对这台 iPhone，前往「设备连接」一键配对").font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .padding(10)
                    .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .foregroundStyle(.primary)
            } else if coreLocation.authorizationStatus == .denied || coreLocation.authorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text("未开启定位权限，无法自动触发外设订阅").font(.caption.weight(.semibold))
                    Spacer()
                    Button("去开启") {
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
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.realLocationRestoredNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelocTheme.emerald)
                    Text("已恢复本机真实 GPS 定位")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelocTheme.emerald)
                    Spacer()
                }
                .padding(10)
                .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let err = viewModel.snapshot.lastError {
                Text("上次错误：\(err)")
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                if viewModel.snapshot.isRunning {
                    if viewModel.pendingLocation != nil {
                        RelocPrimaryButton(
                            title: "更新到此位置",
                            systemImage: "paperplane.fill",
                            gradient: RelocTheme.accentGradient
                        ) {
                            viewModel.applyPendingLocationUpdate()
                        }
                    }
                    RelocPrimaryButton(
                        title: "停止并恢复",
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: "开始定位",
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
    }

    @ViewBuilder
    private var restoreLocationStatusBanner: some View {
        if viewModel.needsRestoreLocationRefresh {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text("外设连接已断开，但系统仍在缓存上次定位（室内弱信号常见）。点击下方一键刷新定位服务即可立即恢复真实位置。")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                Button {
                    RelocTheme.hapticMedium()
                    viewModel.launchOneTapRestoreRefresh()
                } label: {
                    Label("一键刷新定位服务（恢复真实位置）", systemImage: "pip.enter")
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
                Text("已发送断开与失效报文，正在唤醒本机真实 GPS 恢复定位…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("立即刷新") {
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
                    Text("外设 GPS 已 100% 生效")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RelocTheme.emerald)
                    Text("系统已确认外设来源（isProducedByAccessory = true），可直接切去任意 App")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .injectingPendingLock where viewModel.needsLocationServiceRefresh:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text("NMEA 已连通，但系统仍在沿用本机缓存定位。点击下方一键刷新（含悬浮 5 秒倒计时）即可 100% 强制切换。")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 8) {
                    Button {
                        RelocTheme.hapticMedium()
                        viewModel.launchOneTapLocationRefresh()
                    } label: {
                        Label("一键刷新定位服务（浮窗指引）", systemImage: "pip.enter")
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
                        Text("重试")
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
                        ? "正在连接设备回环并完成 MFi 鉴权…"
                        : (viewModel.injectionPhase == .waitingSubscription
                            ? "鉴权成功，正在自动唤醒系统外设 GPS 订阅…"
                            : "正在高速注入 NMEA 坐标，等待系统锁定外设源…")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                if viewModel.snapshot.authenticated {
                    Button("强制刷新") {
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

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchFocused = false

        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
            viewModel.selectWGSLocation(TargetLocation(latitude: lat, longitude: lon, altitude: viewModel.targetLocation.altitude))
            cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
            searchResults = []
            searchText = ""
            return
        }

        isSearching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        let search = MKLocalSearch(request: req)
        search.start { response, _ in
            Task { @MainActor in
                isSearching = false
                searchResults = response?.mapItems ?? []
            }
        }
    }
}

// MARK: - Interactive MKMapView Wrapper

private struct InteractiveMKMapView: UIViewRepresentable {
    let activeCoordinate: CLLocationCoordinate2D
    let isSessionRunning: Bool
    let pendingCoordinate: CLLocationCoordinate2D?
    let mapSource: MapSource
    let mapStyle: MapDisplayStyle
    let isDarkMode: Bool
    @Binding var cameraTarget: CLLocationCoordinate2D?
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapCoordinate: onTapCoordinate)
    }

    func makeUIView(context: Context) -> RelocMKMapView {
        let mapView = RelocMKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        applyMapSource(to: mapView, context: context)

        let activeAnn = TaggedAnnotation(kind: .active)
        activeAnn.coordinate = activeCoordinate
        activeAnn.title = "当前位置"
        mapView.addAnnotation(activeAnn)
        context.coordinator.activeAnnotation = activeAnn

        let region = MKCoordinateRegion(
            center: activeCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapView.setRegion(region, animated: false)
        return mapView
    }

    func updateUIView(_ uiView: RelocMKMapView, context: Context) {
        context.coordinator.onTapCoordinate = onTapCoordinate
        context.coordinator.isSessionRunning = isSessionRunning

        applyMapSource(to: uiView, context: context)

        if let activeAnn = context.coordinator.activeAnnotation {
            if abs(activeAnn.coordinate.latitude - activeCoordinate.latitude) > 1e-9 ||
               abs(activeAnn.coordinate.longitude - activeCoordinate.longitude) > 1e-9 {
                activeAnn.coordinate = activeCoordinate
            }
            if let markerView = uiView.view(for: activeAnn) as? MKMarkerAnnotationView {
                markerView.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
            }
        }

        if let pending = pendingCoordinate {
            if let existing = context.coordinator.pendingAnnotation {
                existing.coordinate = pending
            } else {
                let ann = TaggedAnnotation(kind: .pending)
                ann.coordinate = pending
                ann.title = "待更新位置"
                uiView.addAnnotation(ann)
                context.coordinator.pendingAnnotation = ann
            }
        } else if let existing = context.coordinator.pendingAnnotation {
            uiView.removeAnnotation(existing)
            context.coordinator.pendingAnnotation = nil
        }

        if let target = cameraTarget {
            let region = MKCoordinateRegion(
                center: target,
                span: uiView.region.span.latitudeDelta > 0.25
                    ? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    : uiView.region.span
            )
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                cameraTarget = nil
            }
        }
    }

    private func applyMapSource(to mapView: RelocMKMapView, context: Context) {
        mapView.hideNativeAttribution = mapSource.isPureWGS84

        if mapSource == .appleNative {
            if let overlay = context.coordinator.tileOverlay {
                mapView.removeOverlay(overlay)
                context.coordinator.tileOverlay = nil
                context.coordinator.appliedTileKey = nil
            }
            switch mapStyle {
            case .standard: mapView.mapType = .standard
            case .satellite: mapView.mapType = .satellite
            case .hybrid: mapView.mapType = .hybrid
            }
            return
        }

        let key = mapSource.rawValue
        guard context.coordinator.appliedTileKey != key else { return }

        if let existing = context.coordinator.tileOverlay {
            mapView.removeOverlay(existing)
        }
        mapView.mapType = .standard
        let overlay = GlobalWGSTileOverlay(source: mapSource, isDarkMode: isDarkMode)
        mapView.addOverlay(overlay, level: .aboveLabels)
        context.coordinator.tileOverlay = overlay
        context.coordinator.appliedTileKey = key
    }

    final class TaggedAnnotation: MKPointAnnotation {
        enum Kind { case active, pending }
        let kind: Kind
        init(kind: Kind) {
            self.kind = kind
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onTapCoordinate: (CLLocationCoordinate2D) -> Void
        var isSessionRunning = false
        var activeAnnotation: TaggedAnnotation?
        var pendingAnnotation: TaggedAnnotation?
        var tileOverlay: MKTileOverlay?
        var appliedTileKey: String?

        init(onTapCoordinate: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onTapCoordinate = onTapCoordinate
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapCoordinate(coord)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
    }
}

/// MKMapView subclass that suppresses the underlying MapKit/AutoNavi attribution logo
/// when custom WGS-84 tiles completely replace map content (`canReplaceMapContent = true`).
private final class RelocMKMapView: MKMapView {
    var hideNativeAttribution: Bool = false {
        didSet {
            updateAttributionSubviews()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateAttributionSubviews()
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        updateAttributionSubviews()
    }

    private func updateAttributionSubviews() {
        Self.applyAttributionVisibility(in: self, hide: hideNativeAttribution, depth: 0)
    }

    private static func applyAttributionVisibility(in root: UIView, hide: Bool, depth: Int) {
        guard depth <= 4 else { return }
        for subview in root.subviews {
            let className = String(describing: type(of: subview))
            // Never touch map rendering canvas, overlays, annotations, compass, or scale bar.
            if className.contains("BasicMap")
                || className.contains("VKMap")
                || className.contains("Annotation")
                || className.contains("Overlay")
                || className.contains("Compass")
                || className.contains("Scale") {
                continue
            }
            if isAttributionView(subview, className: className) {
                subview.isHidden = hide
                subview.alpha = hide ? 0.0 : 1.0
                continue
            }
            applyAttributionVisibility(in: subview, hide: hide, depth: depth + 1)
        }
    }

    private static func isAttributionView(_ view: UIView, className: String) -> Bool {
        if className.localizedCaseInsensitiveContains("Attribution")
            || className.localizedCaseInsensitiveContains("Logo")
            || className.localizedCaseInsensitiveContains("Legal") {
            return true
        }
        if let label = view as? UILabel, let text = label.text,
           (text.contains("高德") || text.localizedCaseInsensitiveContains("AutoNavi") || text.contains("法律") || text.localizedCaseInsensitiveContains("Legal")) {
            return true
        }
        return false
    }
}

/// High-DPI cached global WGS-84 tile overlay (`canReplaceMapContent = true`) that completely replaces
/// AutoNavi/AMap tiles on Mainland China devices while keeping MapKit gestures, annotations, and search.
private final class GlobalWGSTileOverlay: MKTileOverlay {
    private let source: MapSource
    private let isDarkMode: Bool

    private static let tileSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "reloc_map_tiles"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = [
            "User-Agent": "Reloc/1.0 (iOS; https://github.com/reloc)",
        ]
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    init(source: MapSource, isDarkMode: Bool) {
        self.source = source
        self.isDarkMode = isDarkMode
        super.init(urlTemplate: nil)
        self.canReplaceMapContent = true
        self.minimumZ = 0
        self.maximumZ = 19
        self.tileSize = CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        switch source {
        case .globalStreet:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        case .globalOSM:
            return URL(string: "https://tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png")!
        case .globalSatellite:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        case .appleNative:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let tileURL = url(forTilePath: path)
        var req = URLRequest(url: tileURL)
        req.cachePolicy = .returnCacheDataElseLoad
        Self.tileSession.dataTask(with: req) { data, response, error in
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result(nil, NSError(domain: "RelocTileOverlay", code: http.statusCode))
                return
            }
            result(data, error)
        }.resume()
    }
}

// MARK: - Places Sheet (Favorites + Recent 30 History + Rename)

private struct PlacesSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onSelect: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var newFavoriteName = ""
    @State private var renamingFavorite: FavoriteLocation?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分类", selection: $tab) {
                    Text("收藏 (\(viewModel.favorites.count))").tag(0)
                    Text("最近记录 (\(viewModel.recents.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    if tab == 0 {
                        Section("收藏当前选中位置") {
                            HStack {
                                TextField("输入名称", text: $newFavoriteName)
                                Button("保存") {
                                    viewModel.saveCurrentAsFavorite(name: newFavoriteName)
                                    newFavoriteName = ""
                                }
                                .disabled(newFavoriteName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        Section("已保存收藏") {
                            if viewModel.favorites.isEmpty {
                                Text("暂无收藏地点").foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.favorites) { fav in
                                    Button {
                                        viewModel.selectWGSLocation(
                                            TargetLocation(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                                            name: fav.name,
                                            address: fav.subtitle
                                        )
                                        onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fav.name).foregroundStyle(.primary)
                                            Text(fav.subtitle ?? String(format: "%.5f, %.5f", fav.latitude, fav.longitude))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteFavorite(id: fav.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        Button {
                                            renameText = fav.name
                                            renamingFavorite = fav
                                        } label: {
                                            Label("重命名", systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    } else {
                        Section {
                            if viewModel.recents.isEmpty {
                                Text("暂无最近使用记录").foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.recents) { item in
                                    Button {
                                        viewModel.selectWGSLocation(
                                            TargetLocation(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                                            name: item.name,
                                            address: item.subtitle
                                        )
                                        onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name).foregroundStyle(.primary)
                                            Text(item.subtitle ?? String(format: "%.5f, %.5f", item.latitude, item.longitude))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteRecent(id: item.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("最近使用（最多 30 条）")
                                Spacer()
                                if !viewModel.recents.isEmpty {
                                    Button("清空") { viewModel.clearRecents() }
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("收藏与历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("重命名收藏", isPresented: Binding(
                get: { renamingFavorite != nil },
                set: { if !$0 { renamingFavorite = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) { renamingFavorite = nil }
                Button("保存") {
                    if let fav = renamingFavorite {
                        viewModel.renameFavorite(id: fav.id, newName: renameText)
                    }
                    renamingFavorite = nil
                }
            }
        }
    }
}

private struct ManualCoordinateSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onApply: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var latText = ""
    @State private var lonText = ""
    @State private var altText = ""
    @State private var favoriteName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("WGS-84 坐标") {
                    TextField("纬度 (-90 ~ 90)", text: $latText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("经度 (-180 ~ 180)", text: $lonText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("海拔 (米)", text: $altText)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section("保存到收藏（可选）") {
                    TextField("地点名称", text: $favoriteName)
                }
            }
            .navigationTitle("手动输入坐标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if let lat = Double(latText), let lon = Double(lonText),
                           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
                            let alt = Double(altText) ?? viewModel.inspectedLocation.altitude
                            viewModel.selectWGSLocation(
                                TargetLocation(latitude: lat, longitude: lon, altitude: alt),
                                name: favoriteName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : favoriteName
                            )
                            if !favoriteName.trimmingCharacters(in: .whitespaces).isEmpty {
                                viewModel.saveCurrentAsFavorite(name: favoriteName)
                            }
                            onApply(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                let loc = viewModel.inspectedLocation
                latText = String(format: "%.6f", loc.latitude)
                lonText = String(format: "%.6f", loc.longitude)
                altText = String(format: "%.1f", loc.altitude)
            }
        }
    }
}
