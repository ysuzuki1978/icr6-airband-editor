import Foundation

public enum AirbandService: String, Decodable, Sendable {
    case TWR, GND, ATI, RDO, DLV, APP, DEP, ARR, ASR, TCA, RMP, CMP

    public var title: String {
        switch self {
        case .TWR: "タワー（離着陸）"
        case .GND: "グラウンド（地上移動）"
        case .ATI: "ATIS（空港情報放送）"
        case .RDO: "ラジオ（飛行場情報）"
        case .DLV: "デリバリー（出発許可）"
        case .APP: "アプローチ（進入）"
        case .DEP: "ディパーチャー（出発）"
        case .ARR: "アライバル（到着）"
        case .ASR: "レーダー"
        case .TCA: "TCA（ターミナル管制）"
        case .RMP: "ランプ（駐機場）"
        case .CMP: "カンパニー（航空会社との連絡）"
        }
    }
}

public struct JapanAirport: Identifiable, Decodable, Sendable {
    public struct Frequency: Decodable, Sendable {
        public let khz: Int
        public let services: [AirbandService]
        public let station: String?
        public let memorySuffix: String?
    }

    public let icao: String
    public let iata: String?
    public let name: String
    public let region: String
    public let companySourceURL: URL?
    public let channels: [Frequency]

    public var id: String { icao }
    public var bankName: String { iata ?? String(icao.suffix(3)) }
    public var sourceURL: URL {
        URL(string: "https://nagodede.github.io/aip/japan/documents/\(icao)_full.pdf")!
    }

    public func presets() -> [AirbandPreset] {
        var counts = [AirbandService: Int]()
        return channels.compactMap { frequency in
            guard let service = frequency.services.first else { return nil }
            let count = counts[service, default: 0] + 1
            counts[service] = count
            let suffix = count == 1
                ? service.rawValue
                : String(service.rawValue.prefix(2)) + String(count, radix: 36, uppercase: true)
            return AirbandPreset(airport: icao, khz: frequency.khz, services: frequency.services,
                                 station: frequency.station, name: bankName + (frequency.memorySuffix ?? suffix))
        }
    }
}

public struct AirbandPreset: Identifiable, Sendable {
    public let airport: String
    public let khz: Int
    public let services: [AirbandService]
    public let station: String?
    public let name: String

    public var id: String { "\(airport)-\(khz)" }
    public var mhz: String { "\(khz / 1000).\(String(format: "%03d", khz % 1000))" }
}

public enum JapanAirband {
    public static let home = "RJOM"
    public static let maximumAirports = 4

    public static func load() throws -> [JapanAirport] {
        let url = Bundle.main.url(forResource: "JapanAirports", withExtension: "json")
            ?? Bundle.module.url(forResource: "JapanAirports", withExtension: "json")
        guard let url else { throw R6Error("国内空港の周波数データが見つかりません。") }
        return try JSONDecoder().decode([JapanAirport].self, from: Data(contentsOf: url))
    }

    public struct Replacement: Sendable {
        public let image: RadioImage
        public let registered: Int
        public let previousCount: Int
        public let scanBanks: [String]
    }

    public static func replace(_ airports: [JapanAirport], in original: RadioImage,
                               excluding: Set<String> = [], names: [String: String] = [:]) throws -> Replacement {
        guard (1...maximumAirports).contains(airports.count),
              Set(airports.map(\.id)).count == airports.count else {
            throw R6Error("空港を1〜4か所選んでください。")
        }
        let groups = airports.map { airport in
            (airport: airport, presets: airport.presets().filter { !excluding.contains($0.id) })
        }.filter { !$0.presets.isEmpty }
        guard !groups.isEmpty else { throw R6Error("登録する周波数を1件以上選んでください。") }

        var image = original
        let previous = original.channels.filter(\.active)
        for channel in previous { image.remove(channel.id) }
        for bank in RadioImage.bankLetters.indices where !original.bankName(bank).isEmpty {
            try image.setBankName("", at: bank)
        }

        var empty = (0..<RadioImage.channelCount).makeIterator()
        var registered = 0
        var scanBanks = [String]()
        for (bank, group) in groups.enumerated() {
            let (airport, presets) = group
            try image.setBankName(airport.bankName, at: bank)
            scanBanks.append(image.bankLabel(bank))
            for preset in presets {
                guard let number = empty.next() else { throw R6Error("登録に必要な空きチャンネルが足りません。") }
                var draft = ChannelDraft(image.channel(number))
                draft.frequency = preset.mhz
                draft.name = names[preset.id] ?? preset.name
                draft.mode = .am
                draft.bank = bank
                do {
                    try image.apply(draft, to: number)
                } catch {
                    throw R6Error("\(airport.bankName) \(preset.mhz) MHz　\(error.localizedDescription)")
                }
                registered += 1
            }
        }
        return Replacement(image: image, registered: registered, previousCount: previous.count, scanBanks: scanBanks)
    }
}
