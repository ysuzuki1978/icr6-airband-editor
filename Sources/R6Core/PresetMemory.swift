public struct PresetReplacement: Sendable {
    public let image: RadioImage
    public let registered: Int
    public let previousCount: Int
    public let scanBanks: [String]
}

public struct PresetPlan: Sendable {
    public struct Bank: Sendable {
        struct Channel: Sendable {
            let frequency: String
            let name: String
        }

        public let name: String
        public let title: String
        public let mode: ReceiveMode
        let channels: [Channel]

        public var count: Int { channels.count }
    }

    public let banks: [Bank]
    public var channelCount: Int { banks.reduce(0) { $0 + $1.count } }

    public init(airports: [JapanAirport] = [], excludingAirband: Set<String> = [],
                airbandNames: [String: String] = [:], railwayRegions: [RailwayRegion] = [],
                includingRailway: Set<RailwayPreset.ID> = []) throws {
        let air = airports.isEmpty ? [] : try JapanAirband.banks(airports, excluding: excludingAirband, names: airbandNames)
        let rail = railwayRegions.isEmpty ? [] : try JapanRailways.banks(railwayRegions, including: includingRailway)
        self.init(banks: air + rail)
    }

    init(banks: [Bank]) {
        self.banks = banks.filter { !$0.channels.isEmpty }
    }

    public func replace(in original: RadioImage) throws -> PresetReplacement {
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
        return PresetReplacement(image: image, registered: registered, previousCount: previous.count, scanBanks: scanBanks)
    }
}
