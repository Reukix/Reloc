import CoreLocation
import SwiftUI
import UIKit

/// Deterministic, harmonious accent color for a user-defined favorite group tag.
enum FavoriteGroupColor {
    private static let palette: [Color] = [
        RelocTheme.accent,
        RelocTheme.emerald,
        Color(red: 0.94, green: 0.52, blue: 0.14),
        Color(red: 0.56, green: 0.34, blue: 0.92),
        Color(red: 0.88, green: 0.28, blue: 0.52),
        Color(red: 0.08, green: 0.64, blue: 0.72),
        Color(red: 0.34, green: 0.42, blue: 0.92),
    ]

    static func color(for group: String?) -> Color {
        guard let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return RelocTheme.accent
        }
        var hash: UInt64 = 5381
        for byte in trimmed.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Crisp miniature vector preview of a saved or planned route polyline (with start/finish markers).
struct RoutePolylineThumbnail: View {
    let points: [RoutePoint]
    let isFreehand: Bool
    let isClosedLoop: Bool
    var size: CGFloat = 48

    private var strokeColor: Color {
        if isClosedLoop { return RelocTheme.emerald }
        return isFreehand ? Color(red: 0.48, green: 0.36, blue: 0.95) : RelocTheme.accent
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(strokeColor.opacity(0.10))

            Canvas { context, canvasSize in
                // Subtle map-style reference grid
                let step = canvasSize.width / 3.0
                var gridPath = Path()
                for idx in 1...2 {
                    let pos = CGFloat(idx) * step
                    gridPath.move(to: CGPoint(x: pos, y: 4))
                    gridPath.addLine(to: CGPoint(x: pos, y: canvasSize.height - 4))
                    gridPath.move(to: CGPoint(x: 4, y: pos))
                    gridPath.addLine(to: CGPoint(x: canvasSize.width - 4, y: pos))
                }
                context.stroke(gridPath, with: .color(strokeColor.opacity(0.12)), lineWidth: 0.6)

                guard points.count >= 2 else { return }

                // Project WGS-84 coordinates into local equirectangular space for true aspect ratio.
                let refLat = points[0].latitude
                let cosLat = max(0.05, cos(refLat * .pi / 180.0))
                let strideStep = max(1, points.count / 90)
                var projected: [CGPoint] = []
                projected.reserveCapacity(min(points.count, 96))
                var idx = 0
                while idx < points.count {
                    let pt = points[idx]
                    projected.append(CGPoint(x: pt.longitude * cosLat, y: -pt.latitude))
                    idx += strideStep
                }
                if let last = points.last {
                    let lastProj = CGPoint(x: last.longitude * cosLat, y: -last.latitude)
                    if projected.last != lastProj {
                        projected.append(lastProj)
                    }
                }

                guard let firstP = projected.first else { return }
                var minX = firstP.x, maxX = firstP.x
                var minY = firstP.y, maxY = firstP.y
                for p in projected {
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minY = min(minY, p.y); maxY = max(maxY, p.y)
                }

                let inset: CGFloat = 9.0
                let drawW = max(1.0, canvasSize.width - inset * 2)
                let drawH = max(1.0, canvasSize.height - inset * 2)
                let spanX = max(maxX - minX, 1e-6)
                let spanY = max(maxY - minY, 1e-6)
                let scale = min(drawW / spanX, drawH / spanY)
                let offsetX = (canvasSize.width - spanX * scale) * 0.5
                let offsetY = (canvasSize.height - spanY * scale) * 0.5

                func mapPoint(_ p: CGPoint) -> CGPoint {
                    CGPoint(
                        x: offsetX + (p.x - minX) * scale,
                        y: offsetY + (p.y - minY) * scale
                    )
                }

                var routePath = Path()
                let mappedStart = mapPoint(projected[0])
                routePath.move(to: mappedStart)
                for i in 1..<projected.count {
                    routePath.addLine(to: mapPoint(projected[i]))
                }

                let style = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                context.stroke(routePath, with: .color(Color.white.opacity(0.85)), style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                context.stroke(routePath, with: .color(strokeColor), style: style)

                // Start dot (emerald) & finish dot (crimson, unless closed loop)
                let startRect = CGRect(x: mappedStart.x - 3.0, y: mappedStart.y - 3.0, width: 6.0, height: 6.0)
                context.fill(Path(ellipseIn: startRect), with: .color(RelocTheme.emerald))
                context.stroke(Path(ellipseIn: startRect), with: .color(.white), lineWidth: 1.0)

                if !isClosedLoop, let lastP = projected.last {
                    let mappedEnd = mapPoint(lastP)
                    let endRect = CGRect(x: mappedEnd.x - 3.0, y: mappedEnd.y - 3.0, width: 6.0, height: 6.0)
                    context.fill(Path(ellipseIn: endRect), with: .color(RelocTheme.crimson))
                    context.stroke(Path(ellipseIn: endRect), with: .color(.white), lineWidth: 1.0)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(strokeColor.opacity(0.24), lineWidth: 0.8)
        )
    }
}

// MARK: - Places & Routes Sheet

struct PlacesSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onSelect: (CLLocationCoordinate2D) -> Void
    let onImportGPX: () -> Void
    let onExportGPX: (SavedRoute) -> Void
    let onExportFavoriteGPX: (FavoriteLocation) -> Void
    let onExportBackup: () -> Void
    let onImportBackup: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var searchQuery = ""
    /// `nil` = all groups, `""` = ungrouped only, non-empty = specific group
    @State private var selectedGroupFilter: String? = nil

    @State private var isQuickSaveFavoriteExpanded = false
    @State private var newFavoriteName = ""
    @State private var newFavoriteGroup = ""
    @State private var newFavoriteNote = ""

    @State private var isQuickSaveRouteExpanded = false
    @State private var newRouteName = ""

    @State private var editingFavorite: FavoriteLocation?
    @State private var renamingRoute: SavedRoute?
    @State private var renameText = ""
    @State private var copiedItemID: UUID?

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredFavorites: [FavoriteLocation] {
        viewModel.favorites.filter { fav in
            if let groupFilter = selectedGroupFilter {
                if groupFilter.isEmpty {
                    if let g = fav.group, !g.isEmpty { return false }
                } else if fav.group != groupFilter {
                    return false
                }
            }
            guard !normalizedQuery.isEmpty else { return true }
            return fav.name.localizedCaseInsensitiveContains(normalizedQuery)
                || (fav.subtitle?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || (fav.group?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || (fav.note?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
        }
    }

    private var filteredRoutes: [SavedRoute] {
        guard !normalizedQuery.isEmpty else { return viewModel.savedRoutes }
        return viewModel.savedRoutes.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.preset.title.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.loopMode.title.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var filteredRecents: [RecentLocation] {
        guard !normalizedQuery.isEmpty else { return viewModel.recents }
        return viewModel.recents.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedQuery)
                || ($0.subtitle?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
        }
    }

    private var defaultCurrentRouteName: String {
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topControlsHeader

                List {
                    if tab == 0 {
                        favoritesTabContent
                    } else if tab == 1 {
                        routesTabContent
                    } else {
                        recentsTabContent
                    }
                }
                .listStyle(.insetGrouped)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.tr("places.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            dismiss()
                            onExportBackup()
                        } label: {
                            Label(L10n.tr("backup.action.export"), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            dismiss()
                            onImportBackup()
                        } label: {
                            Label(L10n.tr("backup.action.import"), systemImage: "square.and.arrow.down")
                        }
                        if !viewModel.isRouteSessionActive {
                            Divider()
                            Button {
                                dismiss()
                                onImportGPX()
                            } label: {
                                Label(L10n.tr("gpx.action.import"), systemImage: "map")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                if viewModel.controlMode == .route {
                    tab = 1
                }
            }
            .sheet(item: $editingFavorite) { fav in
                FavoriteEditorSheet(viewModel: viewModel, favorite: fav)
            }
            .alert(L10n.tr("places.rename.title"), isPresented: Binding(
                get: { renamingRoute != nil },
                set: { if !$0 { renamingRoute = nil } }
            )) {
                TextField(L10n.tr("places.rename.placeholder"), text: $renameText)
                Button(L10n.tr("common.cancel"), role: .cancel) {
                    renamingRoute = nil
                }
                Button(L10n.tr("common.save")) {
                    if let route = renamingRoute {
                        viewModel.renameSavedRoute(id: route.id, newName: renameText)
                    }
                    renamingRoute = nil
                }
            }
        }
    }

    // MARK: - Unified Top Controls Header

    private var topControlsHeader: some View {
        VStack(spacing: 8) {
            Picker(L10n.tr("places.picker"), selection: $tab) {
                Text(L10n.format("places.tab.favorites", viewModel.favorites.count)).tag(0)
                Text(L10n.format("places.tab.routes", viewModel.savedRoutes.count)).tag(1)
                Text(L10n.format("places.tab.recents", viewModel.recents.count)).tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("places.search.placeholder"), text: $searchQuery)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.28), lineWidth: 0.6)
            )
            .padding(.horizontal, 16)

            if tab == 0 && !viewModel.favoriteGroups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        groupFilterPill(
                            title: L10n.tr("places.group.all"),
                            count: viewModel.favorites.count,
                            dotColor: nil,
                            value: nil
                        )
                        ForEach(viewModel.favoriteGroups, id: \.self) { grp in
                            let count = viewModel.favorites.filter { $0.group == grp }.count
                            groupFilterPill(
                                title: grp,
                                count: count,
                                dotColor: FavoriteGroupColor.color(for: grp),
                                value: grp
                            )
                        }
                        let ungroupedCount = viewModel.favorites.filter { ($0.group ?? "").isEmpty }.count
                        if ungroupedCount > 0 {
                            groupFilterPill(
                                title: L10n.tr("places.group.ungrouped"),
                                count: ungroupedCount,
                                dotColor: .secondary,
                                value: ""
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func groupFilterPill(title: String, count: Int, dotColor: Color?, value: String?) -> some View {
        let selected = selectedGroupFilter == value
        return Button {
            RelocTheme.hapticLight()
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedGroupFilter = value
            }
        } label: {
            HStack(spacing: 5) {
                if let dotColor {
                    Circle()
                        .fill(selected ? Color.white : dotColor)
                        .frame(width: 6.5, height: 6.5)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(selected ? RelocTheme.accent : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(selected ? Color.clear : Color(uiColor: .separator).opacity(0.25), lineWidth: 0.6)
            )
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 0: Favorites

    @ViewBuilder
    private var favoritesTabContent: some View {
        Section {
            quickSaveFavoriteCard
        }

        Section {
            if filteredFavorites.isEmpty {
                emptyStateRow(
                    icon: normalizedQuery.isEmpty ? "heart.circle" : "magnifyingglass",
                    title: normalizedQuery.isEmpty ? L10n.tr("places.favorites.empty") : L10n.tr("places.search.empty")
                )
            } else {
                ForEach(filteredFavorites) { fav in
                    favoriteRow(fav)
                }
            }
        } header: {
            HStack {
                Text(L10n.tr("places.favorites.header"))
                Spacer()
                Text("\(filteredFavorites.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var quickSaveFavoriteCard: some View {
        let inspected = viewModel.inspectedLocation
        let alreadySaved = viewModel.isCurrentInspectedFavorite

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((alreadySaved ? Color.pink : RelocTheme.accent).opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: alreadySaved ? "heart.fill" : "mappin.and.ellipse")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(alreadySaved ? .pink : RelocTheme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(viewModel.selectedPlaceName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if alreadySaved {
                            Text(L10n.tr("places.saved_badge"))
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.pink.opacity(0.14), in: Capsule())
                                .foregroundStyle(.pink)
                        }
                    }
                    Text(String(format: "%.5f, %.5f · %.0fm", inspected.latitude, inspected.longitude, inspected.altitude))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    RelocTheme.hapticLight()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if !isQuickSaveFavoriteExpanded {
                            if newFavoriteName.isEmpty {
                                newFavoriteName = viewModel.selectedPlaceName
                            }
                            isQuickSaveFavoriteExpanded = true
                        } else {
                            isQuickSaveFavoriteExpanded = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isQuickSaveFavoriteExpanded ? "chevron.up" : "plus")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(isQuickSaveFavoriteExpanded ? L10n.tr("common.cancel") : L10n.tr("common.save"))
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        isQuickSaveFavoriteExpanded ? Color.secondary.opacity(0.14) : RelocTheme.accent,
                        in: Capsule()
                    )
                    .foregroundStyle(isQuickSaveFavoriteExpanded ? Color.primary : Color.white)
                }
                .buttonStyle(.plain)
            }

            if isQuickSaveFavoriteExpanded {
                Divider()

                VStack(spacing: 8) {
                    TextField(L10n.tr("places.name.placeholder"), text: $newFavoriteName)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    TextField(L10n.tr("places.edit.group.placeholder"), text: $newFavoriteGroup)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    if !viewModel.favoriteGroups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(viewModel.favoriteGroups, id: \.self) { grp in
                                    let selected = newFavoriteGroup.trimmingCharacters(in: .whitespacesAndNewlines) == grp
                                    let tint = FavoriteGroupColor.color(for: grp)
                                    Button {
                                        RelocTheme.hapticLight()
                                        newFavoriteGroup = selected ? "" : grp
                                    } label: {
                                        Text(grp)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4.5)
                                            .background(selected ? tint : tint.opacity(0.14), in: Capsule())
                                            .foregroundStyle(selected ? .white : tint)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    TextField(L10n.tr("places.edit.note.placeholder"), text: $newFavoriteNote)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    let trimmedName = newFavoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button {
                        viewModel.saveCurrentAsFavorite(
                            name: trimmedName,
                            group: newFavoriteGroup,
                            note: newFavoriteNote
                        )
                        newFavoriteName = ""
                        newFavoriteGroup = ""
                        newFavoriteNote = ""
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isQuickSaveFavoriteExpanded = false
                        }
                        RelocTheme.hapticSuccess()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "heart.fill")
                                .font(.caption.weight(.bold))
                            Text(L10n.tr("places.action.add_favorite"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(trimmedName.isEmpty ? Color.secondary.opacity(0.3) : RelocTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func isActiveTarget(_ lat: Double, _ lon: Double) -> Bool {
        let loc = viewModel.inspectedLocation
        return abs(loc.latitude - lat) < 1e-4 && abs(loc.longitude - lon) < 1e-4
    }

    private func selectFavorite(_ fav: FavoriteLocation) {
        RelocTheme.hapticLight()
        if viewModel.controlMode == .route && !viewModel.isRouteSessionActive {
            viewModel.addRouteWaypointWGS(
                RoutePoint(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                name: fav.name
            )
            if let last = viewModel.routeMapWaypointCoordinates.last {
                onSelect(last)
            }
        } else {
            viewModel.selectWGSLocation(
                TargetLocation(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                name: fav.name,
                address: fav.subtitle
            )
            onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
        }
        dismiss()
    }

    private func copyCoordinates(id: UUID, name: String, lat: Double, lon: Double, alt: Double) {
        UIPasteboard.general.string = "\(name) (\(String(format: "%.6f, %.6f, %.1fm", lat, lon, alt)))"
        RelocTheme.hapticSuccess()
        copiedItemID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedItemID == id {
                copiedItemID = nil
            }
        }
    }

    private func favoriteRow(_ fav: FavoriteLocation) -> some View {
        let groupTint = FavoriteGroupColor.color(for: fav.group)
        let active = isActiveTarget(fav.latitude, fav.longitude)
        let isCopied = copiedItemID == fav.id

        return HStack(spacing: 11) {
            Button {
                selectFavorite(fav)
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill((active ? RelocTheme.emerald : groupTint).opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: active ? "location.fill" : (fav.group?.isEmpty == false ? "tag.fill" : "mappin.circle.fill"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(active ? RelocTheme.emerald : groupTint)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(fav.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if active {
                                Text(L10n.tr("places.active_badge"))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(RelocTheme.emerald.opacity(0.16), in: Capsule())
                                    .foregroundStyle(RelocTheme.emerald)
                            }

                            if let grp = fav.group, !grp.isEmpty {
                                Text(grp)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 1.5)
                                    .background(groupTint.opacity(0.14), in: Capsule())
                                    .foregroundStyle(groupTint)
                                    .lineLimit(1)
                            }
                        }

                        if let subtitle = fav.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Text(String(format: "%.5f, %.5f · %.0fm", fav.latitude, fav.longitude, fav.altitude))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)

                        if let note = fav.note, !note.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "note.text")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    selectFavorite(fav)
                } label: {
                    Label(
                        viewModel.controlMode == .route && !viewModel.isRouteSessionActive
                            ? L10n.tr("places.action.add_waypoint")
                            : L10n.tr("places.action.locate"),
                        systemImage: viewModel.controlMode == .route && !viewModel.isRouteSessionActive ? "plus.circle" : "location.fill"
                    )
                }
                Button {
                    editingFavorite = fav
                } label: {
                    Label(L10n.tr("places.action.edit"), systemImage: "pencil")
                }
                Button {
                    copyCoordinates(id: fav.id, name: fav.name, lat: fav.latitude, lon: fav.longitude, alt: fav.altitude)
                } label: {
                    Label(L10n.tr("places.action.copy_coords"), systemImage: "doc.on.doc")
                }
                Button {
                    dismiss()
                    onExportFavoriteGPX(fav)
                } label: {
                    Label(L10n.tr("gpx.action.export"), systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    viewModel.deleteFavorite(id: fav.id)
                } label: {
                    Label(L10n.tr("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: isCopied ? "checkmark.circle.fill" : "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCopied ? RelocTheme.emerald : Color(uiColor: .secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
            }
            .tint(.primary)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                viewModel.deleteFavorite(id: fav.id)
            } label: {
                Label(L10n.tr("common.delete"), systemImage: "trash")
            }
            Button {
                editingFavorite = fav
            } label: {
                Label(L10n.tr("places.action.edit"), systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                dismiss()
                onExportFavoriteGPX(fav)
            } label: {
                Label(L10n.tr("gpx.action.export_short"), systemImage: "square.and.arrow.up")
            }
            .tint(RelocTheme.accent)
        }
    }

    // MARK: - Tab 1: Routes

    @ViewBuilder
    private var routesTabContent: some View {
        if !viewModel.isRouteSessionActive || (viewModel.plannedRoutePoints.count >= 2 && !viewModel.isPlanningRoute) {
            Section {
                if viewModel.plannedRoutePoints.count >= 2 && !viewModel.isPlanningRoute {
                    quickSaveCurrentRouteCard
                }
                if !viewModel.isRouteSessionActive {
                    Button {
                        RelocTheme.hapticLight()
                        dismiss()
                        onImportGPX()
                    } label: {
                        HStack(spacing: 11) {
                            SettingsIconBadge(systemName: "square.and.arrow.down", color: RelocTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("gpx.action.import"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(L10n.tr("places.gpx.import_subtitle"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .tint(.primary)
                }
            }
        }

        Section {
            if filteredRoutes.isEmpty {
                emptyStateRow(
                    icon: normalizedQuery.isEmpty ? "point.filled.topleft.down.curvedto.point.bottomright.up" : "magnifyingglass",
                    title: normalizedQuery.isEmpty ? L10n.tr("places.routes.empty") : L10n.tr("places.search.empty")
                )
            } else {
                ForEach(filteredRoutes) { route in
                    savedRouteRow(route)
                }
            }
        } header: {
            HStack {
                Text(L10n.tr("places.routes.header"))
                Spacer()
                Text("\(filteredRoutes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quickSaveCurrentRouteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                RoutePolylineThumbnail(
                    points: viewModel.plannedRoutePoints,
                    isFreehand: viewModel.isCurrentRouteFreehand,
                    isClosedLoop: viewModel.routeLoopMode == .loop,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("places.routes.save_current"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(viewModel.routePreset.title) · \(RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters)) · \(viewModel.routeLoopMode.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    RelocTheme.hapticLight()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if !isQuickSaveRouteExpanded {
                            if newRouteName.isEmpty {
                                newRouteName = defaultCurrentRouteName
                            }
                            isQuickSaveRouteExpanded = true
                        } else {
                            isQuickSaveRouteExpanded = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isQuickSaveRouteExpanded ? "chevron.up" : "bookmark.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(isQuickSaveRouteExpanded ? L10n.tr("common.cancel") : L10n.tr("common.save"))
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        isQuickSaveRouteExpanded ? Color.secondary.opacity(0.14) : RelocTheme.emerald,
                        in: Capsule()
                    )
                    .foregroundStyle(isQuickSaveRouteExpanded ? Color.primary : Color.white)
                }
                .buttonStyle(.plain)
            }

            if isQuickSaveRouteExpanded {
                Divider()
                HStack(spacing: 8) {
                    TextField(L10n.tr("route.save.placeholder"), text: $newRouteName)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    let trimmed = newRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button {
                        viewModel.saveCurrentRoute(name: trimmed)
                        newRouteName = ""
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isQuickSaveRouteExpanded = false
                        }
                        RelocTheme.hapticSuccess()
                    } label: {
                        Text(L10n.tr("common.save"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(trimmed.isEmpty ? Color.secondary.opacity(0.3) : RelocTheme.emerald, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func routeSpeedOrPaceText(_ route: SavedRoute) -> String {
        if (route.preset == .walking || route.preset == .running),
           let pace = RouteGeometry.formatPacePerKm(route.speedMetersPerSecond) {
            return pace
        }
        return RouteGeometry.formatSpeedKmh(route.speedMetersPerSecond)
    }

    private func routeGoalBadgeText(_ route: SavedRoute) -> String? {
        if let dist = route.targetDistanceMeters, dist >= 200.0 {
            return L10n.format("route.goal.chip.distance", dist / 1000.0)
        }
        if let laps = route.targetLaps, laps >= 1, route.loopMode != .once {
            return L10n.format("route.goal.chip.laps", laps)
        }
        return nil
    }

    private func loadRoute(_ route: SavedRoute) {
        guard !viewModel.snapshot.isRunning else { return }
        RelocTheme.hapticLight()
        viewModel.loadSavedRoute(route)
        if let first = viewModel.routeMapWaypointCoordinates.first {
            onSelect(first)
        }
        dismiss()
    }

    private func savedRouteRow(_ route: SavedRoute) -> some View {
        let eta = RouteGeometry.formatETA(seconds: route.totalDistanceMeters / max(0.3, route.speedMetersPerSecond))
        let typeTint: Color = route.isFreehand ? Color(red: 0.48, green: 0.36, blue: 0.95) : RelocTheme.accent

        return HStack(spacing: 12) {
            Button {
                loadRoute(route)
            } label: {
                HStack(spacing: 12) {
                    RoutePolylineThumbnail(
                        points: route.points,
                        isFreehand: route.isFreehand,
                        isClosedLoop: route.loopMode == .loop,
                        size: 50
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(route.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(route.isFreehand ? L10n.tr("route.creation.freehand") : L10n.tr("route.creation.road"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(typeTint.opacity(0.13), in: Capsule())
                                .foregroundStyle(typeTint)
                                .lineLimit(1)
                        }

                        HStack(spacing: 5) {
                            HStack(spacing: 3) {
                                Image(systemName: route.preset.systemImage)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(route.preset.title)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Text(RouteGeometry.formatDistance(route.totalDistanceMeters))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)

                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Text(routeSpeedOrPaceText(route))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }

                        HStack(spacing: 5) {
                            routeMetaChip(
                                icon: route.loopMode.systemImage,
                                text: route.loopMode.title,
                                tint: route.loopMode == .loop ? RelocTheme.emerald : .secondary
                            )
                            routeMetaChip(
                                icon: "clock",
                                text: eta,
                                tint: .secondary
                            )
                            if let goalText = routeGoalBadgeText(route) {
                                routeMetaChip(
                                    icon: "flag.checkered",
                                    text: goalText,
                                    tint: RelocTheme.amber
                                )
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.snapshot.isRunning)

            Menu {
                if !viewModel.snapshot.isRunning {
                    Button {
                        loadRoute(route)
                    } label: {
                        Label(L10n.tr("places.action.load_route"), systemImage: "play.circle")
                    }
                }
                Button {
                    dismiss()
                    onExportGPX(route)
                } label: {
                    Label(L10n.tr("gpx.action.export"), systemImage: "square.and.arrow.up")
                }
                Button {
                    renameText = route.name
                    renamingRoute = route
                } label: {
                    Label(L10n.tr("common.rename"), systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    viewModel.deleteSavedRoute(id: route.id)
                } label: {
                    Label(L10n.tr("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
            }
            .tint(.primary)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                viewModel.deleteSavedRoute(id: route.id)
            } label: {
                Label(L10n.tr("common.delete"), systemImage: "trash")
            }
            Button {
                renameText = route.name
                renamingRoute = route
            } label: {
                Label(L10n.tr("common.rename"), systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                dismiss()
                onExportGPX(route)
            } label: {
                Label(L10n.tr("gpx.action.export_short"), systemImage: "square.and.arrow.up")
            }
            .tint(RelocTheme.accent)
        }
    }

    private func routeMetaChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.11), in: Capsule())
        .foregroundStyle(tint)
    }

    private func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = L10n.currentLanguage == .system ? Locale.current : L10n.currentLanguage.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Tab 2: Recents

    @ViewBuilder
    private var recentsTabContent: some View {
        Section {
            if filteredRecents.isEmpty {
                emptyStateRow(
                    icon: normalizedQuery.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    title: normalizedQuery.isEmpty ? L10n.tr("places.recents.empty") : L10n.tr("places.search.empty")
                )
            } else {
                ForEach(filteredRecents) { item in
                    recentRow(item)
                }
            }
        } header: {
            HStack {
                Text(L10n.tr("places.recents.header"))
                Spacer()
                if !viewModel.recents.isEmpty {
                    Button(L10n.tr("common.clear")) {
                        RelocTheme.hapticMedium()
                        viewModel.clearRecents()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RelocTheme.crimson)
                }
            }
        }
    }

    private func isRecentFavorited(_ item: RecentLocation) -> Bool {
        viewModel.favorites.contains {
            abs($0.latitude - item.latitude) < 1e-4 && abs($0.longitude - item.longitude) < 1e-4
        }
    }

    private func selectRecent(_ item: RecentLocation) {
        RelocTheme.hapticLight()
        if viewModel.controlMode == .route && !viewModel.isRouteSessionActive {
            viewModel.addRouteWaypointWGS(
                RoutePoint(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                name: item.name
            )
            if let last = viewModel.routeMapWaypointCoordinates.last {
                onSelect(last)
            }
        } else {
            viewModel.selectWGSLocation(
                TargetLocation(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                name: item.name,
                address: item.subtitle
            )
            onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
        }
        dismiss()
    }

    private func recentRow(_ item: RecentLocation) -> some View {
        let saved = isRecentFavorited(item)
        return HStack(spacing: 11) {
            Button {
                selectRecent(item)
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: "clock.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Text(String(format: "%.5f, %.5f", item.latitude, item.longitude))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(relativeTimeString(for: item.usedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                RelocTheme.hapticLight()
                viewModel.toggleFavorite(forRecent: item)
            } label: {
                Image(systemName: saved ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(saved ? .pink : Color(uiColor: .secondaryLabel))
                    .frame(width: 32, height: 32)
                    .background((saved ? Color.pink.opacity(0.12) : Color(uiColor: .tertiarySystemGroupedBackground)), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                selectRecent(item)
            } label: {
                Label(L10n.tr("places.action.locate"), systemImage: "location.fill")
            }
            Button {
                viewModel.toggleFavorite(forRecent: item)
            } label: {
                Label(L10n.tr("places.action.add_favorite"), systemImage: saved ? "heart.slash" : "heart")
            }
            Button {
                copyCoordinates(id: item.id, name: item.name, lat: item.latitude, lon: item.longitude, alt: item.altitude)
            } label: {
                Label(L10n.tr("places.action.copy_coords"), systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                viewModel.deleteRecent(id: item.id)
            } label: {
                Label(L10n.tr("common.delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                viewModel.deleteRecent(id: item.id)
            } label: {
                Label(L10n.tr("common.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Shared Empty State

    private func emptyStateRow(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}
