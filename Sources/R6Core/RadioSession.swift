import Foundation

public struct R6Error: LocalizedError, Sendable {
    public let errorDescription: String?

    public init(_ message: String) {
        errorDescription = message
    }
}

public struct RadioIdentity: Equatable, Sendable {
    let payload: [UInt8]

    var mapRevision: UInt8 { payload[5] }
}

public struct RadioSnapshot: Sendable {
    public let identity: RadioIdentity
    public let image: RadioImage

    public init(identity: RadioIdentity, image: RadioImage) {
        self.identity = identity
        self.image = image
    }
}

enum CloneCommand: UInt8 {
    case identify = 0xE0, model, download, upload, data, end, result
}

struct CloneFrame: Equatable {
    let fromRadio: Bool
    let command: CloneCommand
    let payload: [UInt8]

    var wire: [UInt8] {
        [0xFE, 0xFE, fromRadio ? 0xEF : 0xEE, fromRadio ? 0xEE : 0xEF, command.rawValue]
            + payload + [0xFD]
    }
}

public final class RadioSession {
    static let model: [UInt8] = [0x32, 0x50, 0x00, 0x01]
    static let end = Array("Icom Inc.73".utf8)

    private let transport: any RadioTransport
    private var incoming: [UInt8] = []
    private var cloneCompletedAt: TimeInterval?

    public static var cableDetected: Bool { USBTransport.detected }

    public convenience init() throws {
        try self.init(transport: USBTransport())
    }

    init(transport: any RadioTransport) {
        self.transport = transport
    }

    public func download(progress: (Double) -> Void = { _ in }) throws -> RadioSnapshot {
        let identity = try identify()
        try send(.download, Self.model)
        var bytes = [UInt8]()
        bytes.reserveCapacity(RadioImage.size)
        while let frame = try nextRadioFrame(timeout: 5) {
            if frame.command == .end {
                guard frame.payload == Self.end, bytes.count == RadioImage.size else {
                    throw R6Error("メモリーの読み出しが途中で終了しました。もう一度読み出してください。")
                }
                let image = try RadioImage(bytes: bytes)
                cloneCompletedAt = ProcessInfo.processInfo.systemUptime
                return RadioSnapshot(identity: identity, image: image)
            }
            guard frame.command == .data else {
                throw R6Error("読み出し中に予期しない応答がありました。")
            }
            let block = try Hex.decode(frame.payload)
            guard block.count >= 5 else { throw R6Error("受信したメモリーデータが短すぎます。") }
            let address = Int(block[0]) << 8 | Int(block[1])
            let length = Int(block[2])
            guard address == bytes.count, length == block.count - 4,
                  address + length <= RadioImage.size, block.reduce(0, &+) == 0 else {
                throw R6Error("受信データに欠落または破損がありました。もう一度読み出してください。")
            }
            bytes.append(contentsOf: block[3..<(3 + length)])
            progress(Double(bytes.count) / Double(RadioImage.size))
        }
        throw R6Error("メモリーの読み出し中に本体からの応答が止まりました。")
    }

    func upload(_ image: RadioImage, to identity: RadioIdentity,
                progress: (Double) -> Void = { _ in }) throws {
        guard try identify() == identity else {
            throw R6Error("読み出したIC-R6と通信相手が一致しません。")
        }
        progress(0)
        try sendAndWaitForEcho(.upload, Self.model)
        for offset in stride(from: 0, to: RadioImage.size, by: 32) {
            let end = min(offset + 32, RadioImage.size)
            var block = [UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset), UInt8(end - offset)]
            block.append(contentsOf: image.bytes[offset..<end])
            block.append(0 &- block.reduce(0, &+))
            try sendAndWaitForEcho(.data, Hex.encode(block))
            progress(Double(end) / Double(RadioImage.size))
        }
        try send(.end, Self.end)
        guard let response = try nextRadioFrame(timeout: 10), response.command == .result,
              response.payload == [0] || response.payload == Array("00".utf8) else {
            throw R6Error("本体から書き込み完了の応答を確認できませんでした。")
        }
        cloneCompletedAt = ProcessInfo.processInfo.systemUptime
    }

    private func identify() throws -> RadioIdentity {
        let completedAt = cloneCompletedAt
        if let completedAt {
            // The IC-R6 can miss requests while it returns from cloning.
            let remaining = 1 - (ProcessInfo.processInfo.systemUptime - completedAt)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        var response = try requestModel()
        if response == nil, completedAt != nil { response = try requestModel() }
        guard let frame = response else {
            throw R6Error("IC-R6が応答しません。本体の電源と、SP端子への差し込みを確認してください。CI-Vの通信速度は「AUTO」または「9600」に設定してください。")
        }
        guard frame.command == .model, frame.payload.count >= 6,
              frame.payload.prefix(4).elementsEqual(Self.model) else {
            throw R6Error("接続先が対応するIC-R6として応答しませんでした。")
        }
        let identity = RadioIdentity(payload: frame.payload)
        guard identity.mapRevision == 1 else {
            throw R6Error("このIC-R6のメモリーデータの版には対応していません。")
        }
        cloneCompletedAt = nil
        return identity
    }

    private func requestModel() throws -> CloneFrame? {
        try send(.identify, [0, 0, 0, 0])
        return try nextRadioFrame(timeout: 3)
    }

    private func send(_ command: CloneCommand, _ payload: [UInt8]) throws {
        try transport.send(CloneFrame(fromRadio: false, command: command, payload: payload).wire)
    }

    private func sendAndWaitForEcho(_ command: CloneCommand, _ payload: [UInt8]) throws {
        let sent = CloneFrame(fromRadio: false, command: command, payload: payload)
        try transport.send(sent.wire)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while let received = try nextFrame(deadline: deadline) {
            if received == sent { return }
            if received.fromRadio {
                throw R6Error("書き込み中に本体から予期しない応答がありました。")
            }
        }
        throw R6Error("書き込み中にケーブルから送信データの応答がなくなりました。")
    }

    private func nextRadioFrame(timeout: TimeInterval) throws -> CloneFrame? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while let frame = try nextFrame(deadline: deadline) {
            if frame.fromRadio { return frame }
        }
        return nil
    }

    private func nextFrame(deadline: TimeInterval) throws -> CloneFrame? {
        while true {
            while let start = incoming.firstIndex(of: 0xFE) {
                if start > 0 { incoming.removeFirst(start) }
                guard incoming.count >= 3 else { break }
                if incoming[1] != 0xFE || incoming[2] == 0xFE {
                    incoming.removeFirst()
                    continue
                }
                guard let end = incoming.dropFirst(2).firstIndex(of: 0xFD) else {
                    if incoming.count > 1024 { throw R6Error("IC-R6の通信データを解析できませんでした。") }
                    break
                }
                let packet = Array(incoming[..<end])
                incoming.removeFirst(end + 1)
                guard packet.count >= 5, let command = CloneCommand(rawValue: packet[4]) else { continue }
                if packet[2] == 0xEF && packet[3] == 0xEE {
                    return CloneFrame(fromRadio: true, command: command, payload: Array(packet.dropFirst(5)))
                }
                if packet[2] == 0xEE && packet[3] == 0xEF {
                    return CloneFrame(fromRadio: false, command: command, payload: Array(packet.dropFirst(5)))
                }
            }
            if incoming.firstIndex(of: 0xFE) == nil { incoming.removeAll(keepingCapacity: true) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            incoming.append(contentsOf: try transport.receive(timeout: UInt32(max(1, min(80, remaining * 1000)))))
        }
    }
}

enum Hex {
    private static let digits = Array("0123456789ABCDEF".utf8)

    static func encode(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] }
    }

    static func decode(_ text: [UInt8]) throws -> [UInt8] {
        func nibble(_ digit: UInt8) throws -> UInt8 {
            switch digit {
            case 48...57: digit - 48
            case 65...70: digit - 55
            case 97...102: digit - 87
            default: throw R6Error("データに16進数以外の文字が含まれています。")
            }
        }
        guard text.count.isMultiple(of: 2) else { throw R6Error("16進数のデータの長さが不正です。") }
        return try stride(from: 0, to: text.count, by: 2).map { try nibble(text[$0]) << 4 | nibble(text[$0 + 1]) }
    }
}
