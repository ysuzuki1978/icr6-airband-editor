import R6Core
import SwiftUI

struct AirbandView: View {
    let model: EditorModel
    @Binding var excluded: Set<String>
    @Binding var names: [String: String]
    let showMemories: () -> Void

    @AppStorage("selectedAirports") private var selection = JapanAirband.home
    @State private var catalog: [JapanAirport] = []
    @State private var query = ""
    @State private var error: String?

    private var selected: [JapanAirport] {
        selection.split(separator: ",").prefix(JapanAirband.maximumAirports)
            .compactMap { code in catalog.first { $0.icao == code } }
    }

    private var matching: [JapanAirport] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = catalog.filter { airport in
            query.isEmpty || [airport.name, airport.icao, airport.iata ?? "", airport.region]
                .contains { $0.localizedStandardContains(query) }
        }
        return visible.filter { $0.id == JapanAirband.home } + visible.filter { $0.id != JapanAirband.home }
    }

    private var checkedCount: Int {
        selected.flatMap { $0.presets() }.filter { !excluded.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            selectionBar
            Divider()
            HSplitView {
                airports.frame(minWidth: 270, idealWidth: 315, maxWidth: 370)
                preview.frame(minWidth: 530, maxWidth: .infinity)
            }
            Divider()
            actions
        }
        .task {
            guard catalog.isEmpty else { return }
            do {
                catalog = try JapanAirband.load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("出張のエアバンド").font(.title2.bold())
                Spacer()
                Text("\(selected.count) / \(JapanAirband.maximumAirports) 空港")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if selected.isEmpty {
                    Text("松山や出張先、乗り継ぎ先を選んでください。")
                        .foregroundStyle(.secondary)
                }
                ForEach(selected) { airport in
                    Button {
                        toggle(airport)
                    } label: {
                        HStack(spacing: 6) {
                            if airport.id == JapanAirband.home {
                                Image(systemName: "house.fill")
                            }
                            Text(airport.bankName).fontWeight(.semibold)
                            Text(airport.name.components(separatedBy: "（")[0]).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.blue.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(airport.name)を選択から外す")
                    .accessibilityLabel("\(airport.name)を選択から外す")
                }
            }
            .frame(minHeight: 26, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var airports: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("国内空港").font(.headline)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("空港名・地域・空港コード", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("検索をクリア")
                    }
                }
                .padding(7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(12)
            if matching.isEmpty {
                ContentUnavailableView("該当する空港がありません", systemImage: "magnifyingglass")
            } else {
                List(matching) { airport in
                    let isSelected = selected.contains { $0.id == airport.id }
                    Button {
                        toggle(airport)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(airport.name).font(.callout.weight(.medium))
                                Text([airport.iata, airport.icao, airport.id == JapanAirband.home ? "ホーム" : airport.region]
                                    .compactMap { $0 }.joined(separator: " · "))
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
                    .disabled(!isSelected && selected.count >= JapanAirband.maximumAirports)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                .listStyle(.plain)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("登録する周波数").font(.headline)
                Spacer()
                Text("VHF AM · メモリーネームは半角6文字")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            if selected.isEmpty {
                ContentUnavailableView("空港を選択", systemImage: "airplane",
                    description: Text("空港ごとに局名と周波数が表示されます。"))
            } else {
                List {
                    ForEach(selected) { airport in
                        let presets = airport.presets()
                        let company = presets.filter { $0.services.contains(.CMP) }
                        Section {
                            ForEach(presets.filter { !$0.services.contains(.CMP) }) { preset in
                                presetRow(preset)
                            }
                        } header: {
                            HStack {
                                Text("\(airport.name) · \(airport.bankName) バンク")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Link("航空路誌 ↗", destination: airport.sourceURL)
                                    .font(.caption)
                            }
                        }
                        if !company.isEmpty {
                            Section {
                                ForEach(company) { preset in
                                    presetRow(preset)
                                }
                            } header: {
                                HStack {
                                    Text("\(airport.bankName) · カンパニー（受信候補）")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if let source = airport.companySourceURL {
                                        Link("受信資料 ↗", destination: source)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func presetRow(_ preset: AirbandPreset) -> some View {
        let enabled = !excluded.contains(preset.id)
        return HStack(spacing: 11) {
            Toggle("登録 \(preset.mhz) MHz", isOn: Binding(
                get: { !excluded.contains(preset.id) },
                set: { checked in
                    if checked { excluded.remove(preset.id) }
                    else { excluded.insert(preset.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Text("\(preset.mhz) MHz").font(.system(.callout, design: .monospaced))
                .frame(width: 104, alignment: .leading)
            Text(preset.station ?? preset.services.map(\.title).joined(separator: " / "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            TextField("メモリーネーム", text: Binding(
                get: { names[preset.id] ?? preset.name },
                set: { names[preset.id] = $0 }
            ))
            .labelsHidden()
            .font(.system(.callout, design: .monospaced))
            .frame(width: 90)
            .disabled(!enabled)
        }
        .padding(.vertical, 2)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if model.image == nil {
                    Text("入れ替えるには、本体から読み出すかICFファイルを開いてください。")
                } else {
                    Text("\(checkedCount) 件を選択中 · 選んだ周波数で通常メモリーを全件入れ替え")
                }
                Text("管制波の出典 · AIP Japan 公開写し 2026-03-01")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("空港セットで全件入れ替え…", action: replace)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.image == nil || model.busy || checkedCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func toggle(_ airport: JapanAirport) {
        var ids = selected.map(\.id)
        if let index = ids.firstIndex(of: airport.id) {
            ids.remove(at: index)
        } else if ids.count < JapanAirband.maximumAirports {
            ids.append(airport.id)
        }
        selection = ids.joined(separator: ",")
        error = nil
    }

    private func replace() {
        do {
            guard try model.replaceAirports(selected, excluding: excluded, names: names) else { return }
            error = nil
            showMemories()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
