import SwiftUI
import UIKit

/// Sheet presenting safe anti-snapback proxy rules (gs-loc only, preserving Apple Maps) for Surge / Shadowrocket / Loon / Clash.
struct AntiSnapbackRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat: ProxyRuleFormat = .surge
    @State private var copiedToast = false
    @State private var sharedFileItem: SharedFileItem?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        SettingsIconBadge(systemName: "shield.lefthalf.filled", color: RelocTheme.emerald)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("proxy_rules.intro.title"))
                                .font(.subheadline.weight(.semibold))
                            Text(L10n.tr("proxy_rules.intro.body"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section(L10n.tr("proxy_rules.format.header")) {
                    Picker(L10n.tr("proxy_rules.format.label"), selection: $selectedFormat) {
                        ForEach(ProxyRuleFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }

                    Text(selectedFormat.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = selectedFormat.content
                        RelocTheme.hapticSuccess()
                        copiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            copiedToast = false
                        }
                    } label: {
                        HStack {
                            Label {
                                Text(copiedToast ? L10n.tr("proxy_rules.copied") : L10n.tr("proxy_rules.copy"))
                                    .foregroundStyle(copiedToast ? RelocTheme.emerald : .primary)
                            } icon: {
                                SettingsIconBadge(
                                    systemName: copiedToast ? "checkmark" : "doc.on.doc",
                                    color: copiedToast ? RelocTheme.emerald : RelocTheme.accent
                                )
                            }
                            Spacer()
                        }
                    }

                    Button {
                        RelocTheme.hapticLight()
                        do {
                            let url = try selectedFormat.writeTemporaryFile()
                            sharedFileItem = SharedFileItem(url: url)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: {
                        HStack {
                            Label {
                                Text(L10n.tr("proxy_rules.export_file"))
                                    .foregroundStyle(.primary)
                            } icon: {
                                SettingsIconBadge(systemName: "square.and.arrow.up", color: .indigo)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } footer: {
                    Text(L10n.tr("proxy_rules.warning.footer"))
                }
            }
            .navigationTitle(L10n.tr("proxy_rules.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
            .sheet(item: $sharedFileItem) { item in
                ActivityShareSheet(url: item.url)
            }
            .alert(L10n.tr("common.alert.title"), isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button(L10n.tr("common.ok"), role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }
}
