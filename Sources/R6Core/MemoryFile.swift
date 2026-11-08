import Foundation

public enum MemoryFile {
    public static func read(_ url: URL) throws -> RadioImage {
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000, let text = String(data: data, encoding: .utf8) else {
            throw R6Error("IC-R6のICFファイルを選択してください。")
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.first == "32500001" else {
            throw R6Error("IC-R6のICFファイルを選択してください。")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(RadioImage.size)
        for line in lines.dropFirst() {
            if line.hasPrefix("#") {
                if line.hasPrefix("#MapRev="), line != "#MapRev=1" {
                    throw R6Error("このICFファイルのデータ形式には対応していません。")
                }
                continue
            }
            let record = try Hex.decode(Array(line.utf8))
            guard record.count >= 4 else { throw R6Error("ICFファイルのレコードが短すぎます。") }
            let address = Int(record[0]) << 8 | Int(record[1])
            let length = Int(record[2])
            guard address == bytes.count, length == record.count - 3, address + length <= RadioImage.size else {
                throw R6Error("ICFファイルのデータが欠落しているか、順序が正しくありません。")
            }
            bytes.append(contentsOf: record.dropFirst(3))
        }
        return try RadioImage(bytes: bytes)
    }

    public static func save(_ image: RadioImage, to url: URL) throws {
        var text = "32500001\r\n#Comment=IC-R6\r\n#MapRev=1\r\n#EtcData=0003\r\n"
        for address in stride(from: 0, to: RadioImage.size, by: 16) {
            let end = min(address + 16, RadioImage.size)
            text += String(format: "%04X%02X", address, end - address)
            text += String(decoding: Hex.encode(image.bytes[address..<end]), as: UTF8.self)
            text += "\r\n"
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public static func backupFolder() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("IC-R6 メモリーエディタ", isDirectory: true)
            .appendingPathComponent("バックアップ", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    public static func backUp(_ image: RadioImage, reason: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "IC-R6_\(formatter.string(from: Date()))_\(reason)_\(UUID().uuidString.prefix(6)).icf"
        let destination = try backupFolder().appendingPathComponent(name)
        try save(image, to: destination)
        return destination
    }
}
