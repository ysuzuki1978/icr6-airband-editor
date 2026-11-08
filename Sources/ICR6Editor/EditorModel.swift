import AppKit
import Observation
import R6Core
import UniformTypeIdentifiers

@MainActor @Observable
final class EditorModel {
    struct Transfer {
        var stage: TransferStage
        var fraction: Double
    }

    private(set) var image: RadioImage?
    private(set) var baseline: RadioImage?
    private(set) var identity: RadioIdentity?
    private var savedImage: RadioImage?
    private var presetUndo: (image: RadioImage, replacedAllMemories: Bool, setName: String)?

    private(set) var channels: [MemoryChannel] = []
    private(set) var changed = Set<Int>()
    private(set) var replacesAllMemories = false
    private(set) var cableConnected = RadioSession.cableDetected
    private(set) var transfer: Transfer?
    private(set) var recentBackup: URL?
    private(set) var status = "IC-R6の電源を入れ、本体から読み出してください。"
    var errorMessage: String?

    var activeCount: Int { channels.filter(\.active).count }
    var busy: Bool { transfer != nil }
    var hasChanges: Bool { image != baseline }
    var canWrite: Bool { image != nil && cableConnected && !busy && (identity == nil || hasChanges) }
    var presetUndoTitle: String? {
        guard !busy, let presetUndo else { return nil }
        return "\(presetUndo.setName)の入れ替えを取り消す"
    }

    func checkCable() {
        cableConnected = RadioSession.cableDetected
    }

    func readRadio() {
        guard !busy, cableConnected, confirmDiscard() else { return }
        transfer = Transfer(stage: .reading, fraction: 0)
        let report = transferReporter()
        Task {
            defer { transfer = nil }
            do {
                let (snapshot, backup) = try await Task.detached(priority: .userInitiated) {
                    try RadioTransfer.read(report: report)
                }.value
                load(snapshot.image, identity: snapshot.identity)
                recentBackup = backup
                status = "本体から \(activeCount) 件を読み出し、バックアップを保存しました。"
            } catch {
                present(error)
            }
        }
    }

    func writeRadio() {
        guard canWrite, let image, let baseline else { return }
        let original = identity.map { RadioSnapshot(identity: $0, image: baseline) }
        let replacingAll = replacesAllMemories
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "IC-R6に書き込みますか？"
        let scope = replacingAll || original == nil
            ? "本体の通常メモリー全1,300枠を入れ替えます。書き込み後に登録されるのは、一覧の \(activeCount) 件です。"
            : "変更したチャンネルとバンク名を本体に反映します。"
        alert.informativeText = scope + "書き込み前の内容は自動で保存します。完了まで本体の電源とケーブルをそのままにしてください。"
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "書き込む").keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn, canWrite, self.image == image,
              self.baseline == baseline, self.identity == original?.identity,
              replacesAllMemories == replacingAll else { return }

        transfer = Transfer(stage: .checking, fraction: 0)
        let report = transferReporter()
        let didBackUp: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in self?.recentBackup = url }
        }
        Task {
            defer { transfer = nil }
            do {
                let (snapshot, count) = try await Task.detached(priority: .userInitiated) {
                    try RadioTransfer.write(image, original: original, replacingAllMemories: replacingAll,
                                            report: report, didBackUp: didBackUp)
                }.value
                load(snapshot.image, identity: snapshot.identity)
                switch count {
                case nil: status = "本体のメモリーを確認しました。"
                case .some where replacingAll:
                    status = "本体の通常メモリーを \(activeCount) 件に入れ替え、読み戻した内容を照合しました。"
                case 0: status = "バンク名を書き込み、読み戻した内容を照合しました。"
                case let count?: status = "\(count) 件を書き込み、読み戻した内容を照合しました。"
                }
            } catch {
                present(error)
            }
        }
    }

    func openFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "IC-R6のメモリーファイルを開く"
        panel.allowedContentTypes = [Self.icfType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    func openFile(_ url: URL) {
        guard !busy, confirmDiscard() else { return }
        do {
            load(try MemoryFile.read(url), identity: nil)
            status = "\(url.lastPathComponent) を開きました。"
        } catch {
            present(error)
        }
    }

    func saveFile() {
        guard !busy, let image else { return }
        let panel = NSSavePanel()
        panel.title = "IC-R6のメモリーファイルを保存"
        panel.allowedContentTypes = [Self.icfType]
        panel.nameFieldStringValue = "IC-R6 メモリー.icf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MemoryFile.save(image, to: url)
            savedImage = image
            status = "\(url.lastPathComponent) を保存しました。"
        } catch {
            present(error)
        }
    }

    func revealBackups() {
        do {
            if let recentBackup {
                NSWorkspace.shared.activateFileViewerSelecting([recentBackup])
            } else {
                NSWorkspace.shared.open(try MemoryFile.backupFolder())
            }
        } catch {
            present(error)
        }
    }

    func saveChannel(_ draft: ChannelDraft, number: Int) throws {
        guard !busy, var image else { return }
        let oldBank = image.channel(number).bank
        try image.apply(draft, to: number)
        if let oldBank, oldBank != draft.bank {
            image.restoreUnusedBankName(oldBank, from: replacesAllMemories ? nil : baseline)
        }
        updateImage(image)
        status = "CH \(image.channel(number).number) の編集を反映しました。"
    }

    func deleteChannel(_ number: Int) {
        guard !busy, var image else { return }
        let bank = image.channel(number).bank
        image.remove(number)
        if let bank { image.restoreUnusedBankName(bank, from: replacesAllMemories ? nil : baseline) }
        updateImage(image)
        status = "CH \(image.channel(number).number) を空きにしました。"
    }

    func undoChannel(_ number: Int) {
        guard !busy, !replacesAllMemories, let baseline, var image else { return }
        let bank = image.channel(number).bank
        let restored = baseline.channel(number)
        if let previousBank = restored.bank,
           image.bankName(previousBank) != baseline.bankName(previousBank) ||
               channels.contains(where: {
                   $0.id != number && $0.bank == previousBank && $0.bankPosition == restored.bankPosition
               }) {
            errorMessage = "元のバンクに別のチャンネルが入っているため、このチャンネルだけは戻せません。"
            return
        }
        image.restoreChannel(number, from: baseline)
        if let bank { image.restoreUnusedBankName(bank, from: baseline) }
        updateImage(image)
        status = "CH \(image.channel(number).number) の編集を取り消しました。"
    }

    func replaceAirports(_ airports: [JapanAirport], excluding: Set<String>, names: [String: String]) throws -> Bool {
        guard !busy, let image else {
            throw R6Error("本体から読み出すか、ICFファイルを開いてください。")
        }
        let result = try JapanAirband.replace(airports, in: image, excluding: excluding, names: names)
        return try applyPreset(result, replacing: image, setName: "空港セット")
    }

    func replaceRailways(_ regions: [RailwayRegion], including: Set<RailwayPreset.ID>) throws -> Bool {
        guard !busy, let image else {
            throw R6Error("本体から読み出すか、ICFファイルを開いてください。")
        }
        let result = try JapanRailways.replace(regions, in: image, including: including)
        return try applyPreset(result, replacing: image, setName: "鉄道セット")
    }

    private func applyPreset(_ result: PresetReplacement, replacing image: RadioImage, setName: String) throws -> Bool {
        let scanBanks = result.scanBanks.joined(separator: " / ")
        if result.image == image {
            status = "この\(setName)は反映済みです。 \(scanBanks)"
            return true
        }
        if result.previousCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "通常メモリーを全件入れ替えますか？"
            alert.informativeText = """
                現在登録されている通常メモリー \(result.previousCount) 件を入れ替え、選んだ \(result.registered) 件だけを登録します。

                入れ替え後　\(scanBanks)

                本体への反映は「本体へ書き込む…」で行います。
                """
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "入れ替える").keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            guard self.image == image, !busy else {
                throw R6Error("編集中のメモリーが変更されました。\(setName)の入れ替えをやり直してください。")
            }
        }
        let undo = (image: image, replacedAllMemories: replacesAllMemories, setName: setName)
        updateImage(result.image)
        presetUndo = undo
        replacesAllMemories = true
        status = "通常メモリーを \(result.registered) 件に入れ替えました。 \(scanBanks)"
        return true
    }

    func undoPresetReplacement() {
        guard !busy, let presetUndo else { return }
        updateImage(presetUndo.image)
        replacesAllMemories = presetUndo.replacedAllMemories
        status = "\(presetUndo.setName)の入れ替えを取り消しました。"
    }

    func confirmDiscard() -> Bool {
        guard hasChanges, image != savedImage else { return true }
        let alert = NSAlert()
        alert.messageText = "編集中の変更を破棄しますか？"
        alert.informativeText = "ファイルへの保存や本体への書き込みが済んでいない変更があります。"
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "変更を破棄").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func load(_ image: RadioImage, identity: RadioIdentity?) {
        baseline = image
        self.identity = identity
        savedImage = image
        replacesAllMemories = false
        updateImage(image)
    }

    private func updateImage(_ image: RadioImage) {
        presetUndo = nil
        self.image = image
        channels = image.channels
        changed = baseline.map { image.changedChannels(from: $0) } ?? []
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription.components(separatedBy: "\n").first ?? "操作を完了できませんでした。"
        checkCable()
    }

    private func transferReporter() -> @Sendable (TransferStage, Double) -> Void {
        { [weak self] stage, fraction in
            Task { @MainActor in
                guard let self, self.busy else { return }
                let percent = Int(fraction * 100)
                if self.transfer?.stage != stage || Int((self.transfer?.fraction ?? 0) * 100) != percent {
                    self.transfer = Transfer(stage: stage, fraction: fraction)
                }
            }
        }
    }

    private static let icfType = UTType(importedAs: "com.icom.clone-format")
}
