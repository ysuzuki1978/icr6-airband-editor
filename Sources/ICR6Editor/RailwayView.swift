import R6Core
import SwiftUI

struct RailwayView: View {
    let model: EditorModel
    @Binding var excluded: Set<RailwayPreset.ID>
    let showMemories: () -> Void

    @AppStorage("selectedRailwayRegions") private var selection = JapanRailways.home
    @State private var catalog: [RailwayRegion] = []
    @State private var error: String?

    private var selected: [RailwayRegion] {
        selection.split(separator: ",").prefix(JapanRailways.maximumRegions)
            .compactMap { id in catalog.first { $0.id == id } }
    }

    private var included: Set<RailwayPreset.ID> {
        Set(selected.flatMap(\.channels).map(\.id)).subtracting(excluded)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("出張先の鉄道無線").font(.title2.bold())
                    Text("地域ごとにバンクを作り、列車指令や駅・車両基地の構内連絡をスキャンできます。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(selected.count) / \(JapanRailways.maximumRegions) 地域")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            HSplitView {
                regionList.frame(minWidth: 220, idealWidth: 260, maxWidth: 315)
                preview.frame(minWidth: 590, maxWidth: .infinity)
            }
            Divider()
            actions
        }
        .task {
            guard catalog.isEmpty else { return }
            do {
                catalog = try JapanRailways.load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var regionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("国内の地域").font(.headline).padding(12)
            List(catalog) { region in
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

    private var actions: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if model.image == nil {
                    Text("入れ替えるには、本体から読み出すかICFファイルを開いてください。")
                } else {
                    Text("\(included.count) 件を選択中 · 選んだ鉄道周波数で通常メモリーを全件入れ替え")
                }
                Text("地域ごとの受信記録・公開資料をもとに収録")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("鉄道セットで全件入れ替え…", action: replace)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.image == nil || model.busy || included.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func toggle(_ region: RailwayRegion) {
        var ids = selected.map(\.id)
        if let index = ids.firstIndex(of: region.id) {
            ids.remove(at: index)
        } else if ids.count < JapanRailways.maximumRegions {
            ids.append(region.id)
        }
        selection = ids.joined(separator: ",")
        error = nil
    }

    private func replace() {
        do {
            guard try model.replaceRailways(selected, including: included) else { return }
            error = nil
            showMemories()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
