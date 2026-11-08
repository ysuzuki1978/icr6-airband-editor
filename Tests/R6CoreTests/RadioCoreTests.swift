import Foundation
import XCTest
@testable import R6Core

final class RadioCoreTests: XCTestCase {
    func testAirportPresetsUseSeparateBanksAndCanBeAppliedTwice() throws {
        let airports = try JapanAirband.load()
        let home = try XCTUnwrap(airports.first { $0.icao == JapanAirband.home })
        let haneda = try XCTUnwrap(airports.first { $0.iata == "HND" })
        XCTAssertEqual(Set(airports.map(\.bankName)).count, airports.count)
        XCTAssertEqual(home.presets().map(\.name), ["MYJTWR", "MYJTW2", "MYJATI", "MYJAPP", "MYJANA", "MYJJAL"])
        XCTAssertEqual(home.presets().map(\.mhz), ["118.350", "126.200", "126.650", "128.000", "130.450", "131.850"])
        XCTAssertEqual(home.presets().first?.services, [.TWR, .GND])
        for airport in airports {
            let presets = airport.presets()
            let company = presets.filter { $0.services.contains(.CMP) }
            XCTAssertFalse(presets.isEmpty)
            XCTAssertEqual(Set(presets.map(\.name)).count, presets.count)
            XCTAssertEqual(Set(presets.map(\.khz)).count, presets.count)
            XCTAssertTrue(presets.allSatisfy { $0.name.utf8.count == 6 })
            XCTAssertTrue(presets.allSatisfy { (118000..<137000).contains($0.khz) && $0.khz != 121500 })
            XCTAssertEqual(airport.companySourceURL?.scheme, company.isEmpty ? nil : "https")
            XCTAssertTrue(company.allSatisfy { $0.services == [.CMP] && $0.station?.isEmpty == false && $0.khz.isMultiple(of: 25) })
        }

        var original = try blankImage()
        var existing = ChannelDraft(original.channel(0))
        existing.frequency = "144.000"
        existing.name = "EXIST"
        existing.bank = 0
        try original.apply(existing, to: 800)
        try original.setBankName("MANUAL", at: 0)
        try original.setBankName("EMPTY", at: 9)
        existing.bank = nil
        try original.apply(existing, to: 1299)
        let result = try JapanAirband.replace([home, haneda], in: original,
            excluding: ["RJOM-126200"], names: ["RJOM-118350": "HOME"])
        XCTAssertEqual(result.previousCount, 2)
        XCTAssertEqual(result.registered, 5 + haneda.channels.count)
        XCTAssertEqual(result.image.channels.filter(\.active).map(\.id), Array(0..<result.registered))
        XCTAssertEqual(result.image.channel(0).name, "HOME")
        XCTAssertEqual(result.image.channel(0).mode, .am)
        XCTAssertEqual(result.image.channel(0).bankSlot, "A00")
        XCTAssertEqual(result.image.channel(3).name, "MYJANA")
        XCTAssertEqual(result.image.channel(4).mode, .am)
        XCTAssertEqual(result.image.channel(4).name, "MYJJAL")
        XCTAssertEqual(result.image.channel(5).bank, 1)
        XCTAssertEqual(result.scanBanks, ["A · MYJ", "B · HND"])
        XCTAssertEqual(result.image.bankName(9), "")
        let merged = try original.mergingEdits(result.image, original: original, replacingAllMemories: true)
        XCTAssertEqual(merged, result.image)
        let repeated = try JapanAirband.replace([home, haneda], in: merged,
            excluding: ["RJOM-126200"], names: ["RJOM-118350": "HOME"])
        XCTAssertEqual(repeated.image, merged)
        var legacy = merged
        try legacy.setBankName("AIRMYJ", at: 0)
        try legacy.setBankName("AIRHND", at: 1)
        let renamed = try JapanAirband.replace([home, haneda], in: legacy,
            excluding: ["RJOM-126200"], names: ["RJOM-118350": "HOME"])
        XCTAssertTrue(renamed.image.changedChannels(from: legacy).isEmpty)
        XCTAssertEqual(try legacy.mergingEdits(renamed.image, original: legacy, replacingAllMemories: true), merged)
        XCTAssertThrowsError(try JapanAirband.replace(Array(airports.prefix(5)), in: original))
        XCTAssertThrowsError(try JapanAirband.replace([home], in: original,
            excluding: Set(home.presets().map(\.id))))
        XCTAssertThrowsError(try JapanAirband.replace([home], in: merged,
            names: ["RJOM-118350": "長すぎる"]))
    }

    func testAirportReplacementUsesCurrentNamesAndChecksAndRemovesOldDestination() throws {
        let catalog = try JapanAirband.load()
        let haneda = try XCTUnwrap(catalog.first { $0.iata == "HND" })
        let itami = try XCTUnwrap(catalog.first { $0.iata == "ITM" })
        let fukuoka = try XCTUnwrap(catalog.first { $0.iata == "FUK" })
        let company = haneda.presets().filter { $0.services == [.CMP] }
        let ana = try XCTUnwrap(company.first { $0.name == "HNDANA" })
        let jal = try XCTUnwrap(company.first { $0.name == "HNDJAL" })
        XCTAssertEqual(ana.mhz, "129.100")
        XCTAssertEqual(jal.mhz, "130.100")

        let before = try JapanAirband.replace([haneda, itami], in: blankImage(),
            names: ["RJTT-118100": "TOWER"])
        let after = try JapanAirband.replace([fukuoka, haneda], in: before.image,
            excluding: [jal.id], names: ["RJTT-118100": "TWRNEW", ana.id: "ANA1"])

        XCTAssertEqual(after.previousCount, before.registered)
        XCTAssertEqual(after.scanBanks, ["A · FUK", "B · HND"])
        XCTAssertEqual(after.image.channels.filter(\.active).count, after.registered)
        let hanedaChannels = after.image.channels.filter { $0.bank == 1 }
        XCTAssertTrue(hanedaChannels.allSatisfy { $0.mode == .am })
        XCTAssertEqual(Set(hanedaChannels.map(\.frequency)), Set(haneda.presets().filter { $0.id != jal.id }.map(\.mhz)))
        XCTAssertEqual(hanedaChannels.first { $0.frequency == ana.mhz }?.name, "ANA1")
        XCTAssertEqual(hanedaChannels.first { $0.frequency == "118.100" }?.name, "TWRNEW")
        XCTAssertFalse(after.image.channels.contains { $0.name.hasPrefix("ITM") })
        XCTAssertEqual(try before.image.mergingEdits(after.image, original: before.image, replacingAllMemories: true), after.image)
        XCTAssertEqual(try after.image.mergingEdits(after.image, original: before.image, replacingAllMemories: true), after.image)
    }

    func testRailwayCatalogProgramsEveryFrequencyInFM() throws {
        let regions = try JapanRailways.load()
        let all = regions.flatMap(\.channels)
        XCTAssertEqual(Set(regions.map(\.id)).count, regions.count)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.contains { $0.group == .other })
        XCTAssertTrue(all.allSatisfy { (1...6).contains($0.name.utf8.count) && $0.source.url.scheme == "https" })
        let original = try blankImage()
        for region in regions {
            XCTAssertFalse(region.channels.isEmpty, region.name)
            XCTAssertEqual(Set(region.channels.map(\.hz)).count, region.channels.count, region.name)
            let result = try JapanRailways.replace([region], in: original, including: Set(region.channels.map(\.id)))
            XCTAssertEqual(result.scanBanks, ["A · \(region.id)"])
            XCTAssertEqual(result.registered, region.channels.count)
            for (index, preset) in region.channels.enumerated() {
                let channel = result.image.channel(index)
                XCTAssertTrue(channel.active)
                XCTAssertEqual(channel.frequency, preset.mhz, preset.name)
                XCTAssertEqual(channel.name, preset.name)
                XCTAssertEqual(channel.mode, .fm)
                XCTAssertEqual(channel.bank, 0)
            }
        }
    }

    func testRailwayReplacementClearsOldAirportsAndHonorsSelection() throws {
        let regions = try JapanRailways.load()
        let shikoku = try XCTUnwrap(regions.first { $0.id == JapanRailways.home })
        let tokai = try XCTUnwrap(regions.first { $0.id == "TOKAI" })
        let hokkaido = try XCTUnwrap(regions.first { $0.id == "HOK" })
        let airports = try JapanAirband.load()
        let original = try JapanAirband.replace(Array(airports.prefix(3)), in: blankImage()).image
        let checked: Set<RailwayPreset.ID> = ["MYJYD1", "MEIT1"]
        let selection = [shikoku, hokkaido, tokai]
        let result = try JapanRailways.replace(selection, in: original, including: checked)
        let active = result.image.channels.filter(\.active)
        XCTAssertEqual(result.previousCount, original.channels.filter(\.active).count)
        XCTAssertEqual(result.scanBanks, ["A · SHK", "B · TOKAI"])
        XCTAssertEqual(result.image.bankName(2), "")
        XCTAssertEqual(active.map(\.frequency), ["365.1875", "153.290"])
        XCTAssertEqual(active.map(\.name), ["MYJYD1", "MEIT1"])
        XCTAssertEqual(active.map(\.bankSlot), ["A00", "B00"])
        XCTAssertEqual(try original.mergingEdits(result.image, original: original, replacingAllMemories: true), result.image)
        XCTAssertEqual(try JapanRailways.replace(selection, in: result.image, including: checked).image, result.image)
        XCTAssertThrowsError(try JapanRailways.replace(selection, in: original, including: []))
        XCTAssertThrowsError(try JapanRailways.replace(Array(regions.prefix(5)), in: original, including: checked))
    }

    func testCombinedPresetKeepsSelectedAirAndRailInSeparateBanks() throws {
        let airports = try JapanAirband.load()
        let matsuyama = try XCTUnwrap(airports.first { $0.id == JapanAirband.home })
        let haneda = try XCTUnwrap(airports.first { $0.iata == "HND" })
        let regions = try JapanRailways.load()
        let shikoku = try XCTUnwrap(regions.first { $0.id == JapanRailways.home })
        let tokai = try XCTUnwrap(regions.first { $0.id == "TOKAI" })
        let plan = try PresetPlan(
            airports: [matsuyama, haneda],
            excludingAirband: Set(haneda.presets().map(\.id)).union(["RJOM-126200"]),
            airbandNames: ["RJOM-118350": "MYJTST"],
            railwayRegions: [shikoku, tokai], includingRailway: ["MYJYD1"]
        )
        XCTAssertEqual(plan.banks.map(\.name), ["MYJ", "SHK"])
        XCTAssertEqual(plan.banks.map(\.count), [5, 1])
        XCTAssertEqual(plan.channelCount, 6)

        let original = try JapanAirband.replace([haneda], in: blankImage()).image
        let result = try plan.replace(in: original)
        let active = result.image.channels.filter(\.active)
        XCTAssertEqual(result.scanBanks, ["A · MYJ", "B · SHK"])
        XCTAssertEqual(result.registered, plan.channelCount)
        XCTAssertEqual(active.map(\.mode), [.am, .am, .am, .am, .am, .fm])
        XCTAssertEqual(active.map(\.bankSlot), ["A00", "A01", "A02", "A03", "A04", "B00"])
        XCTAssertEqual(active.first?.name, "MYJTST")
        XCTAssertEqual(active.last?.frequency, "365.1875")
        XCTAssertEqual(active.last?.name, "MYJYD1")
        XCTAssertEqual(try original.mergingEdits(result.image, original: original, replacingAllMemories: true), result.image)
        XCTAssertThrowsError(try PresetPlan().replace(in: original))
    }

    func testFullReplacementPreservesScanEdgesAndRejectsConcurrentMemoryChanges() throws {
        let catalog = try JapanAirband.load()
        let itami = try XCTUnwrap(catalog.first { $0.iata == "ITM" })
        let original = try blankImage()
        let result = try JapanAirband.replace([itami], in: original)
        var actualBytes = original.bytes
        actualBytes[0x5140] = 42
        var actual = try RadioImage(bytes: actualBytes)
        let merged = try actual.mergingEdits(result.image, original: original, replacingAllMemories: true)
        XCTAssertTrue(merged.sameMemories(as: result.image))
        XCTAssertEqual(merged.bytes[0x5140], 42)

        var draft = ChannelDraft(actual.channel(500))
        draft.frequency = "144.000"
        draft.name = "MANUAL"
        try actual.apply(draft, to: 500)
        XCTAssertThrowsError(try actual.mergingEdits(result.image, original: original, replacingAllMemories: true))
        let withoutBaseline = try actual.mergingEdits(result.image, original: nil)
        XCTAssertFalse(withoutBaseline.channel(500).active)
        XCTAssertEqual(withoutBaseline.bytes[0x5140], 42)
    }

    func testMemoryEditsRoundTripAndPreserveOtherBytes() throws {
        let original = try blankImage()
        var edited = original
        var draft = ChannelDraft(original.channel(0))
        draft.frequency = "１１８．００８３３３"
        draft.name = "air-01"
        draft.mode = .am
        draft.skip = .frequency
        draft.step = 2
        draft.bank = 21
        try edited.apply(draft, to: 0)

        let channel = edited.channel(0)
        XCTAssertTrue(channel.active)
        XCTAssertEqual(channel.frequency, "118.008333")
        XCTAssertEqual(channel.name, "AIR-01")
        XCTAssertEqual(channel.mode, .am)
        XCTAssertEqual(channel.step, 2)
        XCTAssertEqual(channel.skip, .frequency)
        XCTAssertEqual(channel.bankSlot, "Y00")
        XCTAssertEqual(edited.changedChannels(from: original), [0])
        XCTAssertEqual(edited.bytes[0x5140..<0x5F80], original.bytes[0x5140..<0x5F80])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".icf")
        defer { try? FileManager.default.removeItem(at: url) }
        try MemoryFile.save(edited, to: url)
        XCTAssertEqual(try MemoryFile.read(url), edited)

        edited.remove(0)
        XCTAssertFalse(edited.channel(0).active)
        XCTAssertNil(edited.channel(0).bank)
        edited.restoreChannel(0, from: original)
        XCTAssertEqual(edited, original)
    }

    func testInvalidEditsLeaveImageIntact() throws {
        let original = try blankImage()
        var edited = original
        var draft = ChannelDraft(original.channel(0))
        draft.frequency = "118.000001"
        XCTAssertThrowsError(try edited.apply(draft, to: 0))
        draft.frequency = "253.000"
        XCTAssertThrowsError(try edited.apply(draft, to: 0))
        draft.frequency = "118.000"
        draft.name = "日本語"
        XCTAssertThrowsError(try edited.apply(draft, to: 0))
        XCTAssertEqual(edited, original)
    }

    func testMergeKeepsUnrelatedChangesAndChecksCollisions() throws {
        let original = try blankImage()
        var edited = original
        var actual = original
        var draft = ChannelDraft(original.channel(0))
        draft.frequency = "118.000"
        draft.name = "NEW"
        draft.bank = 0
        try edited.apply(draft, to: 0)
        draft.bankPosition = "01"
        try actual.apply(draft, to: 1)

        let merged = try actual.mergingEdits(edited, original: original)
        XCTAssertEqual(merged.channel(0).bankSlot, "A00")
        XCTAssertEqual(merged.channel(1).bankSlot, "A01")
        let replaced = try actual.mergingEdits(edited, original: nil)
        XCTAssertFalse(replaced.channel(1).active)

        draft.bankPosition = "00"
        try actual.apply(draft, to: 1)
        XCTAssertThrowsError(try actual.mergingEdits(edited, original: original))
        draft.bankPosition = "02"
        try actual.apply(draft, to: 0)
        XCTAssertThrowsError(try actual.mergingEdits(edited, original: original))
    }

    func testCloneDownloadAndUploadUsingFragmentedEchoes() throws {
        let image = try blankImage()
        let link = SimulatedCable(image: image, cloneRecoveryTime: 0.5)
        let session = RadioSession(transport: link)
        let snapshot = try session.download()
        XCTAssertEqual(snapshot.image, image)

        var edited = image
        var draft = ChannelDraft(edited.channel(1299))
        draft.frequency = "1309.995"
        draft.name = "END"
        try edited.apply(draft, to: 1299)
        try session.upload(edited, to: snapshot.identity)
        XCTAssertEqual(link.uploaded, edited.bytes)
        XCTAssertEqual(try session.download().image, edited)
    }

    func testDownloadRejectsCorruptBlock() throws {
        let link = SimulatedCable(image: try blankImage(), corrupt: true)
        XCTAssertThrowsError(try RadioSession(transport: link).download())
        XCTAssertTrue(link.uploaded.isEmpty)
    }

    func testOfficialJapanesePresetWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["ICR6_TEST_PRESET"] else {
            throw XCTSkip("Set ICR6_TEST_PRESET to the official Japanese preset ICF.")
        }
        let image = try MemoryFile.read(URL(fileURLWithPath: path))
        XCTAssertEqual(image.channels.filter(\.active).count, 649)
        XCTAssertEqual(image.channel(0).frequency, "156.050")
        XCTAssertEqual(image.channel(0).name, "MRN-01")
        XCTAssertEqual(image.channel(0).bankSlot, "A00")
        XCTAssertEqual(image.bankLabel(0), "A · MARINE")
        XCTAssertTrue(try image.mergingEdits(image, original: nil).sameMemories(as: image))
    }

    private func blankImage() throws -> RadioImage {
        var bytes = [UInt8](repeating: 0, count: RadioImage.size)
        for number in 0..<RadioImage.channelCount { bytes[0x5F80 + number * 2] = 0x9F }
        bytes.replaceSubrange(0x6E50..<RadioImage.size, with: "IcomCloneFormat3".utf8)
        return try RadioImage(bytes: bytes)
    }
}

private final class SimulatedCable: RadioTransport {
    private var image: RadioImage
    let corrupt: Bool
    private let cloneRecoveryTime: TimeInterval
    private var endingClone = false
    private var readyAt: TimeInterval = 0
    private var queue: ArraySlice<UInt8> = []
    private(set) var uploaded: [UInt8] = []

    init(image: RadioImage, corrupt: Bool = false, cloneRecoveryTime: TimeInterval = 0) {
        self.image = image
        self.corrupt = corrupt
        self.cloneRecoveryTime = cloneRecoveryTime
    }

    func send(_ bytes: [UInt8]) throws {
        queue.append(contentsOf: bytes)
        switch CloneCommand(rawValue: bytes[4]) {
        case .identify:
            guard ProcessInfo.processInfo.systemUptime >= readyAt else { return }
            queue.append(0xFF)
            enqueue(.model, RadioSession.model + [0x23, 1])
        case .download:
            for start in stride(from: 0, to: RadioImage.size, by: 32) {
                let end = min(start + 32, RadioImage.size)
                var block = [UInt8(start >> 8), UInt8(truncatingIfNeeded: start), UInt8(end - start)]
                block.append(contentsOf: image.bytes[start..<end])
                block.append((corrupt ? 1 : 0) &- block.reduce(0, &+))
                enqueue(.data, Hex.encode(block))
            }
            enqueue(.end, RadioSession.end)
            endingClone = true
        case .upload:
            uploaded.removeAll()
        case .data:
            let block = try Hex.decode(Array(bytes.dropFirst(5).dropLast()))
            XCTAssertEqual(block.reduce(UInt8(0), &+), 0)
            XCTAssertEqual((Int(block[0]) << 8) + Int(block[1]), uploaded.count)
            uploaded.append(contentsOf: block.dropFirst(3).dropLast())
        case .end:
            image = try RadioImage(bytes: uploaded)
            enqueue(.result, [0])
            endingClone = true
        default:
            XCTFail("Unexpected command")
        }
    }

    func receive(timeout: UInt32) throws -> [UInt8] {
        let count = min(17, queue.count)
        let fragment = Array(queue.prefix(count))
        queue = queue.dropFirst(count)
        if queue.isEmpty, endingClone {
            endingClone = false
            readyAt = ProcessInfo.processInfo.systemUptime + cloneRecoveryTime
        }
        return fragment
    }

    private func enqueue(_ command: CloneCommand, _ payload: [UInt8]) {
        queue.append(contentsOf: CloneFrame(fromRadio: true, command: command, payload: payload).wire)
    }
}
