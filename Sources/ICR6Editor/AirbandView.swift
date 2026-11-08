import R6Core
import SwiftUI

struct AirbandView: View {
    let catalog: [JapanAirport]
    let selected: [JapanAirport]
    let toggle: (JapanAirport) -> Void
    @Binding var excluded: Set<String>
    @Binding var names: [String: String]
    @State private var query = ""

    private var matching: [JapanAirport] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = catalog.filter { airport in
            query.isEmpty || [airport.name, airport.icao, airport.iata ?? "", airport.region]
                .contains { $0.localizedStandardContains(query) }
        }
        return visible.filter { $0.id == JapanAirband.home } + visible.filter { $0.id != JapanAirband.home }
    }

    var body: some View {
        HSplitView {
            airports.frame(minWidth: 250, idealWidth: 300, maxWidth: 350)
            preview.frame(minWidth: 530, maxWidth: .infinity)
        }
    }

    private var airports: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("国内空港").font(.headline)
                    Spacer()
                    Text("\(selected.count) / \(JapanAirband.maximumAirports) 空港")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
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
}
