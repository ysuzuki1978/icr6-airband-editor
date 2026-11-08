import Foundation

public enum TransferStage: String, Sendable {
    case reading = "本体から読み出し中"
    case checking = "書き込み前の確認とバックアップ"
    case writing = "本体へ書き込み中"
    case verifying = "本体から読み戻して確認中"
}

public enum RadioTransfer {
    public static func read(report: (TransferStage, Double) -> Void) throws -> (RadioSnapshot, URL) {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "IC-R6 memory read")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let snapshot = try RadioSession().download { report(.reading, $0) }
        return (snapshot, try MemoryFile.backUp(snapshot.image, reason: "読み出し"))
    }

    public static func write(_ edited: RadioImage, original: RadioSnapshot?, replacingAllMemories: Bool = false,
                             report: (TransferStage, Double) -> Void,
                             didBackUp: (URL) -> Void) throws -> (RadioSnapshot, Int?) {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "IC-R6 memory write")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let radio = try RadioSession()
        let actual = try radio.download { report(.checking, $0) }
        if let original, actual.identity != original.identity {
            throw R6Error("読み出したIC-R6と通信相手が一致しません。本体から読み出し直してください。")
        }
        let merged = try actual.image.mergingEdits(edited, original: original?.image,
                                                   replacingAllMemories: replacingAllMemories)
        guard !merged.sameMemories(as: actual.image) else { return (actual, nil) }

        let backup = try MemoryFile.backUp(actual.image, reason: "書き込み前")
        didBackUp(backup)
        var sending = false
        do {
            try radio.upload(merged, to: actual.identity) {
                sending = true
                report(.writing, $0)
            }
        } catch {
            if !sending {
                throw R6Error("書き込み開始前に本体を確認できませんでした。メモリーの送信は開始していません。\n\(error.localizedDescription)")
            }
            throw R6Error("\(error.localizedDescription) 本体の状態を読み出しで確認してください。書き込み前のデータはバックアップにあります。")
        }

        report(.verifying, 0)
        let verified: RadioSnapshot
        do {
            verified = try radio.download { report(.verifying, $0) }
        } catch {
            throw R6Error("本体から書き込み完了の応答はありましたが、読み戻しに失敗しました。本体の電源を入れ直し、読み出して確認してください。\n\(error.localizedDescription)")
        }
        guard actual.identity == verified.identity, merged.sameMemories(as: verified.image) else {
            throw R6Error("読み戻したメモリーが書き込み内容と一致しません。書き込み前のデータはバックアップにあります。")
        }
        return (verified, merged.changedChannels(from: actual.image).count)
    }
}
