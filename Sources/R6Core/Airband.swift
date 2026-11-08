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

    public typealias Replacement = PresetReplacement

    public static func replace(_ airports: [JapanAirport], in original: RadioImage,
                               excluding: Set<String> = [], names: [String: String] = [:]) throws -> Replacement {
        guard (1...maximumAirports).contains(airports.count),
              Set(airports.map(\.id)).count == airports.count else {
            throw R6Error("空港を1〜4か所選んでください。")
        }
        let banks = airports.map { airport in
            let channels = airport.presets().filter { !excluding.contains($0.id) }.map { preset in
                PresetBank.Channel(frequency: preset.mhz, name: names[preset.id] ?? preset.name)
            }
            return PresetBank(name: airport.bankName, mode: .am, channels: channels)
        }
        return try PresetReplacement.replace(banks, in: original)
    }
}
