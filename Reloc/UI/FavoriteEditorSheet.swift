import CoreLocation
import SwiftUI
import UIKit

private enum FavoriteEditDatum: String, CaseIterable, Identifiable {
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

/// Full editor for a saved FavoriteLocation (name, group tag, note, address, datum-aware coordinates & altitude).
struct FavoriteEditorSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let favorite: FavoriteLocation
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var group = ""
    @State private var note = ""
    @State private var subtitle = ""
    @State private var datum: FavoriteEditDatum = .wgs84
    @State private var latText = ""
    @State private var lonText = ""
    @State private var altText = ""
    @State private var copiedToast = false

    private var previewTint: Color {
        FavoriteGroupColor.color(for: group)
    }

    private var parsedValues: (lat: Double, lon: Double, alt: Double)? {
        guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
              lat.isFinite, lon.isFinite,
              (-90.0...90.0).contains(lat),
              (-180.0...180.0).contains(lon) else {
            return nil
        }
        let altTrimmed = altText.trimmingCharacters(in: .whitespaces)
        let alt: Double
        if altTrimmed.isEmpty {
            alt = favorite.altitude
        } else if let parsedAlt = Double(altTrimmed), parsedAlt.isFinite, (-500.0...50_000.0).contains(parsedAlt) {
            alt = parsedAlt
        } else {
            return nil
        }
        return (lat, lon, alt)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedValues != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(previewTint.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mappin.circle.fill" : "tag.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(previewTint)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? favorite.name : name)
                                    .font(.subheadline.weight(.bold))
                                    .lineLimit(1)
                                let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmedGroup.isEmpty {
                                    Text(trimmedGroup)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6.5)
                                        .padding(.vertical, 1.5)
                                        .background(previewTint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(previewTint)
                                }
                            }
                            Text(subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "\(latText), \(lonText)"
                                 : subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 4)

                        Button {
                            UIPasteboard.general.string = "\(name) (\(latText), \(lonText), \(altText)m)"
                            RelocTheme.hapticSuccess()
                            copiedToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedToast = false
                            }
                        } label: {
                            Image(systemName: copiedToast ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(copiedToast ? RelocTheme.emerald : RelocTheme.accent)
                                .frame(width: 34, height: 34)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }

                Section(L10n.tr("places.edit.section.basic")) {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField(L10n.tr("places.name.placeholder"), text: $name)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "tag")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField(L10n.tr("places.edit.group.placeholder"), text: $group)
                    }
                    if !viewModel.favoriteGroups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(viewModel.favoriteGroups, id: \.self) { existingGroup in
                                    let selected = group.trimmingCharacters(in: .whitespacesAndNewlines) == existingGroup
                                    let chipTint = FavoriteGroupColor.color(for: existingGroup)
                                    Button {
                                        RelocTheme.hapticLight()
                                        group = selected ? "" : existingGroup
                                    } label: {
                                        Text(existingGroup)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                selected ? chipTint : chipTint.opacity(0.14),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(selected ? .white : chipTint)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField(L10n.tr("places.edit.note.placeholder"), text: $note)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "map")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField(L10n.tr("places.edit.address.placeholder"), text: $subtitle)
                    }
                }

                Section {
                    Picker(L10n.tr("manual.datum.label"), selection: $datum) {
                        ForEach(FavoriteEditDatum.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Text(L10n.tr("intent.param.latitude"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minWidth: 72, alignment: .leading)
                        TextField(L10n.tr("manual.lat.placeholder"), text: $latText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 10) {
                        Text(L10n.tr("intent.param.longitude"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minWidth: 72, alignment: .leading)
                        TextField(L10n.tr("manual.lon.placeholder"), text: $lonText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 10) {
                        Text(L10n.tr("intent.param.altitude"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minWidth: 72, alignment: .leading)
                        TextField(L10n.tr("manual.alt.placeholder"), text: $altText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.subheadline.monospacedDigit())
                    }
                } header: {
                    Text(L10n.tr("manual.section.header"))
                } footer: {
                    if parsedValues == nil {
                        Text(L10n.tr("manual.footer.invalid"))
                            .foregroundStyle(RelocTheme.crimson)
                    } else if datum == .gcj02 {
                        Text(L10n.tr("manual.footer.gcj02_hint"))
                    } else {
                        Text(L10n.tr("manual.footer.hint"))
                    }
                }
            }
            .navigationTitle(L10n.tr("places.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) {
                        guard let parsed = parsedValues else { return }
                        let wgs: CLLocationCoordinate2D = datum == .gcj02
                            ? CoordinateTransform.gcj02ToWGS84(lat: parsed.lat, lon: parsed.lon)
                            : CLLocationCoordinate2D(latitude: parsed.lat, longitude: parsed.lon)
                        viewModel.updateFavorite(
                            id: favorite.id,
                            name: name,
                            subtitle: subtitle,
                            group: group,
                            note: note,
                            latitude: wgs.latitude,
                            longitude: wgs.longitude,
                            altitude: parsed.alt
                        )
                        RelocTheme.hapticSuccess()
                        dismiss()
                    }
                    .disabled(!canSave)
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
                name = favorite.name
                group = favorite.group ?? ""
                note = favorite.note ?? ""
                subtitle = favorite.subtitle ?? ""
                datum = .wgs84
                latText = String(format: "%.6f", favorite.latitude)
                lonText = String(format: "%.6f", favorite.longitude)
                altText = String(format: "%.1f", favorite.altitude)
            }
        }
    }
}
