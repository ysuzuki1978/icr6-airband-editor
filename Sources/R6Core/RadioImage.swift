import Foundation

public enum ReceiveMode: UInt8, CaseIterable, Sendable {
    case fm, wfm, am, automatic

    public var title: String {
        switch self {
        case .fm: "FM"
        case .wfm: "WFM"
        case .am: "AM"
        case .automatic: "AUTO"
        }
    }
}

public enum ScanSkip: UInt8, CaseIterable, Sendable {
    case off, memory, reserved, frequency

    public var title: String {
        switch self {
        case .off: "なし"
        case .memory: "SKIP"
        case .reserved: "不明"
        case .frequency: "P SKIP"
        }
    }
}

public struct MemoryChannel: Identifiable, Sendable {
    public let id: Int
    public let active: Bool
    public let name: String
    public let frequency: String
    public let mode: ReceiveMode
    public let step: UInt8
    public let skip: ScanSkip
    public let bank: Int?
    public let bankPosition: Int

    public var number: String { String(format: "%03d", id) }
    public var bankSlot: String {
        guard let bank else { return "" }
        return RadioImage.bankLetters[bank] + String(format: "%02d", bankPosition)
    }
}

public struct ChannelDraft: Equatable, Sendable {
    public static let stepLabels = ["5", "6.25", "8.33", "9", "10", "12.5", "15", "20",
                                    "25", "30", "50", "100", "125", "200", "AUTO", "不明"]
    public var name: String
    public var frequency: String
    public var mode: ReceiveMode
    public var step: UInt8
    public var skip: ScanSkip
    public var bank: Int?
    public var bankPosition: String

    public init(_ channel: MemoryChannel) {
        name = channel.name
        frequency = channel.frequency
        mode = channel.mode
        step = channel.step
        skip = channel.skip
        bank = channel.bank
        bankPosition = channel.bank.map { _ in String(format: "%02d", channel.bankPosition) } ?? ""
    }
}

public struct RadioImage: Equatable, Sendable {
    public static let channelCount = 1300
    public static let bankLetters = "ABCDEFGHIJKLMNOPQRTUWY".map(String.init)
    static let size = 0x6E60
    private static let flagBase = 0x5F80
    private static let bankNames = 0x6D10..<0x6DC0
    private static let nameCodes = Array(" ^^^^^^^()*+^-./0123456789:^^=^^^ABCDEFGHIJKLMNOPQRSTUVWXYZ^^^^^".utf8)
    private static let multipliers = [15_000, 18_750, 25_000, 27_000] // units of 1/3 Hz
    private static let domesticRanges = [
        100_000...252_895_000, 255_100_000...261_895_000, 266_100_000...270_895_000,
        275_100_000...379_895_000, 382_100_000...411_895_000, 415_100_000...809_895_000,
        834_100_000...859_895_000, 889_100_000...914_895_000, 960_100_000...1_309_995_000
    ]

    private(set) var bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        guard bytes.count == Self.size,
              bytes[0x6E50..<Self.size].elementsEqual("IcomCloneFormat3".utf8) else {
            throw R6Error("IC-R6の完全なメモリーデータではありません。")
        }
        self.bytes = bytes
    }

    public func channel(_ number: Int) -> MemoryChannel {
        let offset = number * 16
        let flags = Self.flagBase + number * 2
        let state = bytes[flags]
        let active = state & 0x80 == 0
        let rawBank = Int(state & 0x1F)
        let mode = ReceiveMode(rawValue: (bytes[offset + 3] >> 4) & 3) ?? .automatic
        let skip = ScanSkip(rawValue: (state >> 5) & 3) ?? .off
        return MemoryChannel(
            id: number, active: active, name: active ? decodeName(at: offset) : "",
            frequency: active ? frequency(at: offset) : "",
            mode: active ? mode : .automatic, step: active ? bytes[offset + 3] & 0x0F : 14,
            skip: active ? skip : .off, bank: active && rawBank < Self.bankLetters.count ? rawBank : nil,
            bankPosition: Int(bytes[flags + 1])
        )
    }

    public var channels: [MemoryChannel] {
        (0..<Self.channelCount).map(channel)
    }

    public func bankLabel(_ index: Int) -> String {
        let name = bankName(index)
        return name.isEmpty ? Self.bankLetters[index] : "\(Self.bankLetters[index]) · \(name)"
    }

    public func bankName(_ index: Int) -> String {
        let start = Self.bankNames.lowerBound + index * 8
        return String(decoding: bytes[start..<(start + 6)].prefix { (32...126).contains($0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    mutating func setBankName(_ name: String, at index: Int) throws {
        guard name.utf8.count <= 6, name.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw R6Error("バンク名には半角の英大文字を使ってください。")
        }
        bytes.replaceSubrange(Self.bankNameRange(index), with: name.padding(toLength: 6, withPad: " ", startingAt: 0).utf8)
    }

    public mutating func restoreUnusedBankName(_ index: Int, from baseline: RadioImage?) {
        guard !channels.contains(where: { $0.active && $0.bank == index }) else { return }
        let range = Self.bankNameRange(index)
        if let baseline {
            bytes.replaceSubrange(range, with: baseline.bytes[range])
        } else {
            bytes.replaceSubrange(range, with: repeatElement(0x20, count: range.count))
        }
    }

    private static func bankNameRange(_ index: Int) -> Range<Int> {
        let start = bankNames.lowerBound + index * 8
        return start..<(start + 6)
    }

    public func changedChannels(from baseline: RadioImage) -> Set<Int> {
        Set((0..<Self.channelCount).filter { !channelMatches($0, in: baseline) })
    }

    public mutating func apply(_ draft: ChannelDraft, to number: Int) throws {
        let previous = channel(number)
        let offset = number * 16
        let flags = Self.flagBase + number * 2
        var edited = self
        if !previous.active {
            // Defaults observed in a standard, unfiltered IC-R6 memory.
            edited.bytes.replaceSubrange(offset..<(offset + 16),
                with: [0, 0, 0, 0x0E, 0, 0, 0, 8, 0, 0x72, 0, 0, 0, 0, 0, 0])
            edited.bytes[flags] = 0x1F
            edited.bytes[flags + 1] = 0
        }
        if !previous.active || draft.frequency != previous.frequency {
            try edited.setFrequency(draft.frequency, at: offset)
        }
        if draft.name != previous.name {
            try edited.setName(draft.name, at: offset)
        }
        if draft.step != previous.step {
            guard draft.step < 15 else { throw R6Error("チューニングステップを選択してください。") }
            edited.bytes[offset + 3] = (edited.bytes[offset + 3] & 0xF0) | draft.step
        }
        if !previous.active || draft.mode != previous.mode {
            edited.bytes[offset + 3] = (edited.bytes[offset + 3] & 0xCF) | (draft.mode.rawValue << 4)
        }
        if draft.skip != previous.skip {
            guard draft.skip != .reserved else { throw R6Error("スキップの種類を選択してください。") }
            edited.bytes[flags] = (edited.bytes[flags] & 0x9F) | (draft.skip.rawValue << 5)
        }
        if draft.bank != previous.bank || draft.bankPosition != ChannelDraft(previous).bankPosition {
            try edited.setBank(draft.bank, position: draft.bankPosition, channel: number)
        }
        self = edited
    }

    public mutating func remove(_ number: Int) {
        let flags = Self.flagBase + number * 2
        bytes[flags] = 0x9F
        bytes[flags + 1] = 0
    }

    public mutating func restoreChannel(_ number: Int, from baseline: RadioImage) {
        copyChannel(number, from: baseline)
    }

    public func mergingEdits(_ edited: RadioImage, original: RadioImage?,
                             replacingAllMemories: Bool = false) throws -> RadioImage {
        var merged = self
        if let original, !replacingAllMemories {
            for number in edited.changedChannels(from: original).sorted() {
                guard channelMatches(number, in: original) || channelMatches(number, in: edited) else {
                    throw R6Error("CH \(channel(number).number) は読み出し後に本体でも変更されました。最新のメモリーを読み出してから編集してください。")
                }
                if let bank = edited.channel(number).bank, original.channel(number).bank != bank {
                    let range = Self.bankNameRange(bank)
                    guard bytes[range] == original.bytes[range] || bytes[range] == edited.bytes[range] else {
                        throw R6Error("バンク \(Self.bankLetters[bank]) は読み出し後に本体で変更されました。最新のメモリーを読み出してください。")
                    }
                }
                merged.copyChannel(number, from: edited)
            }
            for bank in Self.bankLetters.indices {
                let range = Self.bankNameRange(bank)
                guard original.bytes[range] != edited.bytes[range] else { continue }
                guard bankMatches(bank, in: original) || bankMatches(bank, in: edited) else {
                    throw R6Error("バンク \(Self.bankLetters[bank]) は読み出し後に本体で変更されました。最新のメモリーを読み出してください。")
                }
                merged.bytes.replaceSubrange(range, with: edited.bytes[range])
            }
        } else {
            if let original, !sameMemories(as: original), !sameMemories(as: edited) {
                throw R6Error("読み出し後に本体の通常メモリーが変更されました。本体から読み出し直し、入れ替える内容を確認してください。")
            }
            let channelRecords = 0..<(Self.channelCount * 16)
            let channelFlags = Self.flagBase..<(Self.flagBase + Self.channelCount * 2)
            for range in [channelRecords, channelFlags, Self.bankNames] {
                merged.bytes.replaceSubrange(range, with: edited.bytes[range])
            }
        }
        try merged.validateBankSlots()
        return merged
    }

    public func sameMemories(as other: RadioImage) -> Bool {
        changedChannels(from: other).isEmpty && bytes[Self.bankNames] == other.bytes[Self.bankNames]
    }

    private func bankMatches(_ bank: Int, in other: RadioImage) -> Bool {
        let range = Self.bankNameRange(bank)
        guard bytes[range] == other.bytes[range] else { return false }
        let members = channels.filter { $0.bank == bank }.map(\.id)
        return members == other.channels.filter { $0.bank == bank }.map(\.id)
            && members.allSatisfy { channelMatches($0, in: other) }
    }

    private func channelMatches(_ number: Int, in other: RadioImage) -> Bool {
        let offset = number * 16
        let flags = Self.flagBase + number * 2
        return bytes[offset..<(offset + 16)] == other.bytes[offset..<(offset + 16)]
            && bytes[flags..<(flags + 2)] == other.bytes[flags..<(flags + 2)]
    }

    private mutating func copyChannel(_ number: Int, from other: RadioImage) {
        let offset = number * 16
        let flags = Self.flagBase + number * 2
        bytes.replaceSubrange(offset..<(offset + 16), with: other.bytes[offset..<(offset + 16)])
        bytes.replaceSubrange(flags..<(flags + 2), with: other.bytes[flags..<(flags + 2)])
    }

    private func frequency(at offset: Int) -> String {
        let code = Int(bytes[offset + 2] >> 2)
        guard code.isMultiple(of: 20), code <= 60 else { return "" }
        let count = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2] & 3) << 16)
        let hz = (count * Self.multipliers[code / 20] + 1) / 3
        let fraction = String(format: "%06d", hz % 1_000_000)
        var digits = fraction
        while digits.count > 3, digits.last == "0" { digits.removeLast() }
        return "\(hz / 1_000_000).\(digits)"
    }

    private mutating func setFrequency(_ input: String, at offset: Int) throws {
        let text = input.folding(options: .widthInsensitive, locale: Locale(identifier: "ja_JP"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard (1...2).contains(parts.count), let whole = parts.first, whole.count <= 4,
              !whole.isEmpty, fraction.count <= 6, !fraction.isEmpty || parts.count == 1,
              whole.utf8.allSatisfy({ (48...57).contains($0) }),
              fraction.utf8.allSatisfy({ (48...57).contains($0) }),
              let mhz = Int(whole) else {
            throw R6Error("周波数をMHzで入力してください。例 118.000")
        }
        let hz = mhz * 1_000_000 + (Int(fraction.padding(toLength: 6, withPad: "0", startingAt: 0)) ?? 0)
        guard Self.domesticRanges.contains(where: { $0.contains(hz) }) else {
            throw R6Error("国内版IC-R6の受信範囲に入る周波数を入力してください。")
        }
        let existingCode = Int(bytes[offset + 2] >> 2)
        let oldMultiplier = existingCode.isMultiple(of: 20) && existingCode <= 60 ? existingCode / 20 : 0
        let oldShift = (Int(bytes[offset + 5]) | (Int(bytes[offset + 6]) << 8)) * Self.multipliers[oldMultiplier]
        let choices = [oldMultiplier] + Self.multipliers.indices.filter { $0 != oldMultiplier }
        for code in choices {
            let unit = Self.multipliers[code]
            let count = (hz * 3 + unit / 2) / unit
            let shift = oldShift / unit
            guard count < (1 << 18), abs(count * unit - hz * 3) <= 1,
                  oldShift.isMultiple(of: unit), shift <= 0xFFFF else { continue }
            bytes[offset] = UInt8(truncatingIfNeeded: count)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: count >> 8)
            bytes[offset + 2] = UInt8(code * 80 + (count >> 16))
            bytes[offset + 5] = UInt8(truncatingIfNeeded: shift)
            bytes[offset + 6] = UInt8(shift >> 8)
            return
        }
        throw R6Error("この周波数を現在のオフセットと組み合わせて保存できません。5、6.25、8.33、9 kHz刻みの周波数を入力してください。")
    }

    private func decodeName(at offset: Int) -> String {
        let packed = bytes[(offset + 11)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let letters = (0..<6).map { index in
            let code = Int((packed >> ((5 - index) * 6)) & 0x3F)
            let letter = Self.nameCodes[code]
            return letter == 94 ? UInt8(63) : letter
        }
        return String(decoding: letters, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private mutating func setName(_ input: String, at offset: Int) throws {
        let name = input.folding(options: .widthInsensitive, locale: Locale(identifier: "ja_JP"))
            .uppercased(with: Locale(identifier: "en_US_POSIX")).trimmingCharacters(in: .whitespaces)
        guard name.utf8.count <= 6 else { throw R6Error("メモリーネームは半角6文字までです。") }
        var packed: UInt64 = 0
        for letter in name.padding(toLength: 6, withPad: " ", startingAt: 0).utf8 {
            guard letter != 94, let code = Self.nameCodes.firstIndex(of: letter) else {
                throw R6Error("メモリーネームに使える文字は英数字、空白、( ) * + - . / : = です。")
            }
            packed = packed << 6 | UInt64(code)
        }
        for index in 0..<5 {
            let byte = UInt8(truncatingIfNeeded: packed >> ((4 - index) * 8))
            let address = offset + 11 + index
            bytes[address] = index == 0 ? (bytes[address] & 0xF0) | byte : byte
        }
    }

    private mutating func setBank(_ bank: Int?, position: String, channel number: Int) throws {
        let flags = Self.flagBase + number * 2
        guard let bank else {
            bytes[flags] = (bytes[flags] & 0xE0) | 0x1F
            bytes[flags + 1] = 0
            return
        }
        guard Self.bankLetters.indices.contains(bank) else { throw R6Error("バンクを選択してください。") }
        let occupied = Set(channels.filter { $0.id != number && $0.active && $0.bank == bank }.map(\.bankPosition))
        let position = position.trimmingCharacters(in: .whitespaces)
        let slot: Int
        if position.isEmpty {
            guard let free = (0..<100).first(where: { !occupied.contains($0) }) else {
                throw R6Error("選んだバンクに空きがありません。")
            }
            slot = free
        } else {
            guard let entered = Int(position), (0..<100).contains(entered) else {
                throw R6Error("バンク内番号を00から99の範囲で入力してください。")
            }
            guard !occupied.contains(entered) else { throw R6Error("このバンク内番号は使用されています。") }
            slot = entered
        }
        bytes[flags] = (bytes[flags] & 0xE0) | UInt8(bank)
        bytes[flags + 1] = UInt8(slot)
    }

    private func validateBankSlots() throws {
        var seen = Set<Int>()
        for channel in channels where channel.active {
            if let bank = channel.bank {
                guard (0..<100).contains(channel.bankPosition),
                      seen.insert(bank * 100 + channel.bankPosition).inserted else {
                    throw R6Error("バンク内番号 \(channel.bankSlot) に重複または範囲外の値があります。")
                }
            }
        }
    }
}
