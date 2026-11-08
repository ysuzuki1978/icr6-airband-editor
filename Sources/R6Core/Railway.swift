import Foundation

public struct RailwayRegion: Identifiable, Decodable, Sendable {
    public let id: String
    public let name: String
    public let channels: [RailwayPreset]
}

public struct RailwayPreset: Identifiable, Decodable, Sendable {
    public enum Source: String, Decodable, Sendable {
        case jr, scheduled, sapporo, fukuoka

        public var title: String {
            switch self {
            case .jr, .scheduled, .sapporo: "受信記録"
            case .fukuoka: "県の資料"
            }
        }

        public var url: URL {
            switch self {
            case .jr: URL(string: "https://rxlife.net/compilation/jr.php")!
            case .scheduled: URL(string: "https://rxlife.net/compilation/scheduled_l1.php")!
            case .sapporo: URL(string: "https://ameblo.jp/dash8rjco/entry-12737753872.html")!
            case .fukuoka: URL(string: "https://www.bousai.pref.fukuoka.jp/files/uploads/2.pdf")!
            }
        }
    }

    public enum Group: String, Decodable, Sendable {
        case jr, other
    }

    public let hz: Int
    public let name: String
    public let operatorName: String
    public let usage: String
    public let group: Group
    public let source: Source

    public var id: String { name }
    public var mhz: String {
        let fraction = String(format: "%06d", hz % 1_000_000)
        var digits = fraction
        while digits.count > 3, digits.last == "0" { digits.removeLast() }
        return "\(hz / 1_000_000).\(digits)"
    }
}

public enum JapanRailways {
    public static let home = "SHK"
    public static let maximumRegions = 4

    public static func load() throws -> [RailwayRegion] {
        let url = Bundle.main.url(forResource: "JapanRailways", withExtension: "json")
            ?? Bundle.module.url(forResource: "JapanRailways", withExtension: "json")
        guard let url else { throw R6Error("鉄道の周波数データが見つかりません。") }
        return try JSONDecoder().decode([RailwayRegion].self, from: Data(contentsOf: url))
    }

    public static func replace(_ regions: [RailwayRegion], in original: RadioImage,
                               including: Set<RailwayPreset.ID>) throws -> PresetReplacement {
        guard (1...maximumRegions).contains(regions.count),
              Set(regions.map(\.id)).count == regions.count else {
            throw R6Error("鉄道の地域を1〜4か所選んでください。")
        }
        let banks = regions.map { region in
            let channels = region.channels.filter { including.contains($0.id) }.map { preset in
                PresetBank.Channel(frequency: preset.mhz, name: preset.name)
            }
            return PresetBank(name: region.id, mode: .fm, channels: channels)
        }
        return try PresetReplacement.replace(banks, in: original)
    }
}
