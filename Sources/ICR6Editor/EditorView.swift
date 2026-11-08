import R6Core
import SwiftUI

struct EditorView: View {
    @MainActor private static let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    private enum Page: String, CaseIterable {
        case presets = "受信セット"
        case memories = "メモリー一覧"
    }

    enum Filter: String, CaseIterable {
        case registered = "登録済み"
        case all = "すべて"
        case changed = "変更済み"
    }

    @Bindable var model: EditorModel
    @State private var page = Page.presets
    @State private var search = ""
    @State private var filter = Filter.registered
    @State private var selection: Int?
    @State private var editing: MemoryChannel?
    @State private var deleting: MemoryChannel?
    @State private var excludedPresets = Set<String>()
    @State private var presetNames = [String: String]()
    @State private var excludedRailwayPresets = Set<RailwayPreset.ID>()

    private var visibleChannels: [MemoryChannel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.channels.filter { channel in
            switch filter {
            case .registered: guard channel.active else { return false }
            case .changed: guard model.changed.contains(channel.id) else { return false }
            case .all: break
            }
            if query.isEmpty { return true }
            let bank = channel.bank.flatMap { model.image?.bankLabel($0) } ?? ""
            return [channel.number, channel.name, channel.frequency, channel.mode.title, channel.bankSlot, bank]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private var selectedChannel: MemoryChannel? {
        guard let selection, model.channels.indices.contains(selection) else { return nil }
        return model.channels[selection]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let transfer = model.transfer {
                transferBar(transfer)
            }
            HStack {
                Picker("画面", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if page == .memories, model.canUndoPresetReplacement {
                    Button("受信セットの入れ替えを取り消す", action: model.undoPresetReplacement)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 11)
            Divider()
            if page == .presets {
                PresetComposerView(model: model, excludedAirband: $excludedPresets, airbandNames: $presetNames,
                                   excludedRailway: $excludedRailwayPresets, showMemories: showPresetMemories)
            } else if model.image != nil {
                HSplitView {
                    channelTable
                        .frame(minWidth: 630, maxWidth: .infinity, maxHeight: .infinity)
                    inspector
                        .frame(minWidth: 265, idealWidth: 300, maxWidth: 345, maxHeight: .infinity,
                               alignment: .topLeading)
                }
            } else {
                welcome
            }
            Divider()
            footer
        }
        .sheet(item: $editing) { channel in
            ChannelEditSheet(model: model, channel: channel)
        }
        .alert("操作を完了できませんでした", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("チャンネルを空きにしますか？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { channel in
            Button("キャンセル", role: .cancel) {}
            Button("空きにする", role: .destructive) { model.deleteChannel(channel.id) }
        } message: { channel in
            Text("CH \(channel.number) を編集画面で空きにします。変更は本体への書き込み時に反映されます。")
        }
        .task {
            while !Task.isCancelled {
                model.checkCable()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: model.image) {
            if selection == nil { selection = visibleChannels.first?.id }
        }
    }

    private func showPresetMemories() {
        search = ""
        filter = .registered
        selection = model.channels.first(where: \.active)?.id
        page = .memories
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let appIcon = Self.appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit()
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: 49, height: 49)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("IC-R6 メモリーエディタ").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle().fill(model.cableConnected ? .green : .orange)
                        .frame(width: 7, height: 7)
                    Text(model.cableConnected ? "OPC-478UC 接続済み" : "OPC-478UC 未接続")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: model.readRadio) {
                Label("本体から読み出す", systemImage: "arrow.down.to.line")
            }
            .disabled(model.busy || !model.cableConnected)
            if page == .memories {
                Button(action: model.writeRadio) {
                    Label("本体へ書き込む…", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canWrite)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("メモリーを読み出す", systemImage: "memorychip")
        } description: {
            Text(model.cableConnected
                 ? "IC-R6の電源を入れ、「本体から読み出す」をクリックしてください。"
                 : "OPC-478UCをMacとIC-R6のSP端子につないでください。")
        } actions: {
            Button("ICFファイルを開く…", action: model.openFile)
                .disabled(model.busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var channelTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("表示", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("名前・周波数・CH・バンク", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("検索をクリア")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 225)
                Button(action: addChannel) {
                    Label("追加…", systemImage: "plus")
                }
                .disabled(model.busy || model.activeCount == RadioImage.channelCount)
            }
            .padding(12)
            Divider()
            Table(visibleChannels, selection: $selection) {
                TableColumn("CH") { channel in
                    HStack(spacing: 5) {
                        Text(channel.number).monospacedDigit()
                        if model.changed.contains(channel.id) {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                                .accessibilityLabel("変更済み")
                        }
                    }
                }.width(62)
                TableColumn("メモリーネーム") { channel in
                    Text(channel.active ? (channel.name.isEmpty ? "—" : channel.name) : "空き")
                        .foregroundStyle(channel.active ? .primary : .secondary)
                }.width(min: 107, ideal: 145)
                TableColumn("周波数 (MHz)") { channel in
                    Text(channel.frequency.isEmpty ? "—" : channel.frequency)
                        .monospacedDigit()
                }.width(min: 102, ideal: 124)
                TableColumn("モード") { channel in
                    Text(channel.active ? channel.mode.title : "—")
                }.width(59)
                TableColumn("バンク") { channel in
                    Text(channel.bankSlot.isEmpty ? "—" : channel.bankSlot)
                        .monospacedDigit()
                }.width(59)
                TableColumn("スキップ") { channel in
                    Text(channel.active ? channel.skip.title : "—")
                }.width(74)
            }
            .contextMenu(forSelectionType: Int.self) { items in
                if let id = items.first, !model.busy {
                    Button(model.channels[id].active ? "編集…" : "登録…") {
                        editing = model.channels[id]
                    }
                }
            } primaryAction: { items in
                if let id = items.first, !model.busy { editing = model.channels[id] }
            }
            HStack {
                Text("\(visibleChannels.count.formatted()) 件表示")
                Spacer()
                Text("\(model.activeCount.formatted()) / 1,300 チャンネル登録済み")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onChange(of: filter) { selectVisibleChannel() }
        .onChange(of: search) { selectVisibleChannel() }
    }

    private var inspector: some View {
        Group {
            if let channel = selectedChannel {
                VStack(alignment: .leading, spacing: 17) {
                    HStack {
                        Text("CH \(channel.number)").font(.title.bold()).monospacedDigit()
                        Spacer()
                        if model.changed.contains(channel.id) {
                            Text("変更済み").font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
                    }
                    if channel.active {
                        Text(channel.name.isEmpty ? "名称未設定" : channel.name)
                            .font(.title3.weight(.medium))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(channel.frequency.isEmpty ? "—" : channel.frequency)
                                .font(.system(.title, design: .monospaced))
                            Text("MHz").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                            detail("受信モード", channel.mode.title)
                            detail("ステップ", ChannelDraft.stepLabels[Int(channel.step)])
                            detail("バンク", channel.bank.map { model.image?.bankLabel($0) ?? "" } ?? "なし")
                            detail("バンク内番号", channel.bankSlot.isEmpty ? "—" : channel.bankSlot)
                            detail("スキップ", channel.skip.title)
                        }
                    } else {
                        Text("空きチャンネル")
                            .foregroundStyle(.secondary)
                        Text("周波数を指定して、このチャンネルに登録できます。")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    Button {
                        editing = channel
                    } label: {
                        Label(channel.active ? "チャンネルを編集…" : "チャンネルに登録…",
                              systemImage: channel.active ? "pencil" : "plus")
                    }
                    .controlSize(.large)
                    .disabled(model.busy)
                    if channel.active {
                        Button("空きにする…", role: .destructive) { deleting = channel }
                            .disabled(model.busy)
                    }
                    if !model.replacesAllMemories, model.changed.contains(channel.id) {
                        Button("この編集を取り消す") { model.undoChannel(channel.id) }
                            .disabled(model.busy)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            } else {
                ContentUnavailableView("チャンネルを選択", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: model.openFile) {
                Label("ファイルを開く…", systemImage: "folder")
            }
            .disabled(model.busy)
            Button(action: model.saveFile) {
                Label("ファイルに保存…", systemImage: "doc")
            }
            .disabled(model.busy || model.image == nil)
            Button(action: model.revealBackups) {
                Label("バックアップ", systemImage: "clock.arrow.circlepath")
            }
            Spacer(minLength: 4)
            if model.hasChanges {
                Text(model.changed.isEmpty ? "バンク名の変更あり" : "変更 \(model.changed.count) 件")
                    .font(.caption.bold()).foregroundStyle(.orange)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func transferBar(_ transfer: EditorModel.Transfer) -> some View {
        HStack(spacing: 14) {
            Text(transfer.stage.rawValue).font(.callout.weight(.semibold))
            ProgressView(value: transfer.fraction)
                .accessibilityLabel(transfer.stage.rawValue)
            Text("\(Int(transfer.fraction * 100)) %")
                .font(.callout.monospacedDigit())
                .frame(width: 45, alignment: .trailing)
            Text("完了まで電源とケーブルをそのままに")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.blue.opacity(0.08))
    }

    private func addChannel() {
        guard let empty = model.channels.first(where: { !$0.active }) else { return }
        search = ""
        filter = .all
        selection = empty.id
        editing = empty
    }

    private func selectVisibleChannel() {
        let rows = visibleChannels
        if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
    }
}

private struct ChannelEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var frequencyFocused: Bool
    @State private var draft: ChannelDraft
    @State private var error: String?
    let model: EditorModel
    let channel: MemoryChannel

    init(model: EditorModel, channel: MemoryChannel) {
        self.model = model
        self.channel = channel
        _draft = State(initialValue: ChannelDraft(channel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.active ? "CH \(channel.number) を編集" : "CH \(channel.number) に登録")
                    .font(.title2.bold())
                Text("編集後に「本体へ書き込む…」を選ぶと、IC-R6に反映されます。")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Form {
                TextField("周波数 (MHz)", text: $draft.frequency, prompt: Text("118.000"))
                    .monospacedDigit()
                    .focused($frequencyFocused)
                TextField("メモリーネーム", text: $draft.name, prompt: Text("半角6文字まで"))
                Picker("受信モード", selection: $draft.mode) {
                    ForEach(ReceiveMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("ステップ (kHz)", selection: $draft.step) {
                    ForEach(0..<(channel.step == 15 ? 16 : 15), id: \.self) {
                        Text(ChannelDraft.stepLabels[$0]).tag(UInt8($0))
                    }
                }
                Picker("スキップ", selection: $draft.skip) {
                    ForEach(ScanSkip.allCases.filter { $0 != .reserved || channel.skip == .reserved }, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("バンク", selection: $draft.bank) {
                    Text("なし").tag(Int?.none)
                    ForEach(RadioImage.bankLetters.indices, id: \.self) { index in
                        Text(model.image?.bankLabel(index) ?? RadioImage.bankLetters[index]).tag(Int?.some(index))
                    }
                }
                .onChange(of: draft.bank) { _, bank in
                    draft.bankPosition = bank == channel.bank ? ChannelDraft(channel).bankPosition : ""
                }
                if draft.bank != nil {
                    TextField("バンク内番号", text: $draft.bankPosition, prompt: Text("自動 · 00〜99"))
                }
            }
            .formStyle(.grouped)
            .frame(height: 325)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("編集を反映", action: apply).keyboardShortcut(.defaultAction)
                    .disabled(draft == ChannelDraft(channel))
            }
            .padding(16)
        }
        .frame(width: 510)
        .defaultFocus($frequencyFocused, true)
    }

    private func apply() {
        do {
            try model.saveChannel(draft, number: channel.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
