import R6Core
import SwiftUI

struct PresetComposerView: View {
    private enum Mode: String, CaseIterable {
        case air = "空港のみ"
        case rail = "鉄道のみ"
        case both = "空港＋鉄道"
    }

    private enum Category: Hashable {
        case air, rail
    }

    let model: EditorModel
    @Binding var excludedAirband: Set<String>
    @Binding var airbandNames: [String: String]
    @Binding var excludedRailway: Set<RailwayPreset.ID>
    let showMemories: () -> Void

    @AppStorage("presetMode") private var mode = Mode.air
    @AppStorage("selectedAirports") private var airportIDs = JapanAirband.home
    @AppStorage("selectedRailwayRegions") private var regionIDs = JapanRailways.home
    @State private var category = Category.air
    @State private var airports: [JapanAirport] = []
    @State private var regions: [RailwayRegion] = []
    @State private var airportError: String?
    @State private var railwayError: String?

    private var selectedAirports: [JapanAirport] {
        airportIDs.split(separator: ",").prefix(JapanAirband.maximumAirports)
            .compactMap { id in airports.first { $0.id == id } }
    }

    private var selectedRegions: [RailwayRegion] {
        regionIDs.split(separator: ",").prefix(JapanRailways.maximumRegions)
            .compactMap { id in regions.first { $0.id == id } }
    }

    private var editingCategory: Category {
        switch mode {
        case .air: .air
        case .rail: .rail
        case .both: category
        }
    }

    var body: some View {
        let plan = Result { try makePlan() }
        VStack(spacing: 0) {
            setup
            Divider()
            switch editingCategory {
            case .air:
                AirbandView(catalog: airports, selected: selectedAirports, toggle: toggleAirport,
                            excluded: $excludedAirband, names: $airbandNames)
            case .rail:
                RailwayView(catalog: regions, selected: selectedRegions, toggle: toggleRegion,
                            excluded: $excludedRailway)
            }
            Divider()
            switch plan {
            case .success(let plan): summary(plan)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .task {
            do { airports = try JapanAirband.load() }
            catch { airportError = error.localizedDescription }
            do { regions = try JapanRailways.load() }
            catch { railwayError = error.localizedDescription }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("受信セットを作る").font(.title2.bold())
                    Text("今回聞きたい空港や鉄道の周波数を選びます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("登録する種類", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: mode) { previous, current in
                    if current == .both { category = previous == .rail ? .rail : .air }
                }
            }
            if mode == .both {
                HStack(spacing: 8) {
                    Text("選ぶ周波数").font(.caption).foregroundStyle(.secondary)
                    Picker("選ぶ周波数", selection: $category) {
                        Label("空港 · AM", systemImage: "airplane").tag(Category.air)
                        Label("鉄道 · FM", systemImage: "tram").tag(Category.rail)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func summary(_ plan: PresetPlan) -> some View {
        let air = plan.banks.enumerated().filter { $0.element.mode == .am }
        let rail = plan.banks.enumerated().filter { $0.element.mode == .fm }
        let needsBoth = mode == .both && (air.isEmpty || rail.isEmpty)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("登録予定").font(.headline)
                Text("\(plan.channelCount) 件 / \(plan.banks.count) バンク")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !air.isEmpty {
                bankRow("空港 · AM", icon: "airplane", color: .blue, banks: air)
            }
            if !rail.isEmpty {
                bankRow("鉄道 · FM", icon: "tram", color: .teal, banks: rail)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if plan.banks.isEmpty {
                        Text("登録する周波数を選んでください。")
                    } else if needsBoth {
                        Text(air.isEmpty ? "空港の周波数も1件以上選んでください。" : "鉄道の周波数も1件以上選んでください。")
                    } else {
                        Text("通常メモリーは、このセットの \(plan.channelCount) 件に入れ替わります。")
                    }
                    if model.image == nil {
                        Text("本体から読み出すか、ICFファイルを開くと一覧に反映できます。")
                    } else {
                        Text("本体への書き込みはメモリー一覧から行います。")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    do {
                        if try model.applyPreset(plan) { showMemories() }
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("メモリー一覧に反映…", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.image == nil || model.busy || plan.banks.isEmpty || needsBoth)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func bankRow(_ title: String, icon: String, color: Color,
                         banks: [(offset: Int, element: PresetPlan.Bank)]) -> some View {
        HStack(spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 86, alignment: .leading)
            ForEach(banks, id: \.offset) { index, bank in
                HStack(spacing: 5) {
                    Text("\(RadioImage.bankLetters[index]) · \(bank.name)")
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                    Text(bank.title.components(separatedBy: "（")[0]).lineLimit(1)
                    Text("\(bank.count) 件").fixedSize().foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }

    private func makePlan() throws -> PresetPlan {
        if mode != .rail, let airportError { throw R6Error(airportError) }
        if mode != .air, let railwayError { throw R6Error(railwayError) }
        let included = Set(selectedRegions.flatMap(\.channels).map(\.id)).subtracting(excludedRailway)
        return try PresetPlan(airports: mode == .rail ? [] : selectedAirports,
                              excludingAirband: excludedAirband, airbandNames: airbandNames,
                              railwayRegions: mode == .air ? [] : selectedRegions, includingRailway: included)
    }

    private func toggleAirport(_ airport: JapanAirport) {
        airportIDs = toggled(airport.id, in: selectedAirports.map(\.id), limit: JapanAirband.maximumAirports)
    }

    private func toggleRegion(_ region: RailwayRegion) {
        regionIDs = toggled(region.id, in: selectedRegions.map(\.id), limit: JapanRailways.maximumRegions)
    }

    private func toggled(_ id: String, in selection: [String], limit: Int) -> String {
        var ids = selection
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else if ids.count < limit {
            ids.append(id)
        }
        return ids.joined(separator: ",")
    }
}
