struct PresetBank {
    struct Channel {
        let frequency: String
        let name: String
    }

    let name: String
    let mode: ReceiveMode
    let channels: [Channel]
}

public struct PresetReplacement: Sendable {
    public let image: RadioImage
    public let registered: Int
    public let previousCount: Int
    public let scanBanks: [String]

    static func replace(_ banks: [PresetBank], in original: RadioImage) throws -> Self {
        let banks = banks.filter { !$0.channels.isEmpty }
        guard !banks.isEmpty else { throw R6Error("登録する周波数を1件以上選んでください。") }

        var image = original
        let previous = original.channels.filter(\.active)
        for channel in previous { image.remove(channel.id) }
        for bank in RadioImage.bankLetters.indices where !original.bankName(bank).isEmpty {
            try image.setBankName("", at: bank)
        }

        var registered = 0
        var scanBanks = [String]()
        for (bank, group) in banks.enumerated() {
            try image.setBankName(group.name, at: bank)
            scanBanks.append(image.bankLabel(bank))
            for preset in group.channels {
                guard registered < RadioImage.channelCount else {
                    throw R6Error("登録に必要な空きチャンネルが足りません。")
                }
                var draft = ChannelDraft(image.channel(registered))
                draft.frequency = preset.frequency
                draft.name = preset.name
                draft.mode = group.mode
                draft.bank = bank
                do {
                    try image.apply(draft, to: registered)
                } catch {
                    throw R6Error("\(group.name) \(preset.frequency) MHz　\(error.localizedDescription)")
                }
                registered += 1
            }
        }
        return Self(image: image, registered: registered, previousCount: previous.count, scanBanks: scanBanks)
    }
}
