import R6Core
import SwiftUI

struct RailwayView: View {
    let catalog: [RailwayRegion]
    let selected: [RailwayRegion]
    let toggle: (RailwayRegion) -> Void
    @Binding var excluded: Set<RailwayPreset.ID>

    private var homeFirst: [RailwayRegion] {
        catalog.filter { $0.id == JapanRailways.home } + catalog.filter { $0.id != JapanRailways.home }
    }

    var body: some View {
        HSplitView {
            regionList.frame(minWidth: 220, idealWidth: 260, maxWidth: 315)
            preview.frame(minWidth: 590, maxWidth: .infinity)
        }
    }

    private var regionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("国内の地域").font(.headline)
                Spacer()
                Text("\(selected.count) / \(JapanRailways.maximumRegions) 地域")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(12)
            List(homeFirst) { region in
                let isSelected = selected.contains { $0.id == region.id }
                Button {
                    toggle(region)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(region.name).font(.callout.weight(.medium))
                            Text(region.id == JapanRailways.home ? "ホーム · 松山ほか" : "\(region.channels.count) 件")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isSelected && selected.count >= JapanRailways.maximumRegions)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .listStyle(.plain)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("登録する周波数").font(.headline)
                Spacer()
                Text("アナログFM · 受信候補").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            if selected.isEmpty {
                ContentUnavailableView("地域を選択", systemImage: "tram",
                    description: Text("JR・私鉄などの周波数と用途が表示されます。"))
            } else {
                List {
                    ForEach(selected) { region in
                        let jr = region.channels.filter { $0.group == .jr }
                        let other = region.channels.filter { $0.group == .other }
                        if !jr.isEmpty {
                            Section("\(region.name) · \(region.id) バンク · JR") {
                                ForEach(jr, content: presetRow)
                            }
                        }
                        if !other.isEmpty {
                            Section("\(region.name) · \(region.id) バンク · 私鉄・公営など") {
                                ForEach(other, content: presetRow)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func presetRow(_ preset: RailwayPreset) -> some View {
        HStack(spacing: 10) {
            Toggle("登録 \(preset.operatorName) \(preset.usage)", isOn: Binding(
                get: { !excluded.contains(preset.id) },
                set: { checked in
                    if checked { excluded.remove(preset.id) }
                    else { excluded.insert(preset.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Text("\(preset.mhz) MHz").font(.system(.callout, design: .monospaced))
                .frame(width: 108, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.operatorName).font(.callout.weight(.medium))
                Text(preset.usage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(preset.name).font(.system(.callout, design: .monospaced))
                .frame(width: 57, alignment: .leading)
                .help("本体のメモリーネーム")
            Link(preset.source.title, destination: preset.source.url).font(.caption)
                .frame(width: 56, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}
