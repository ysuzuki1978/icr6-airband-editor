import CLibUSB
import Foundation
import IOKit

protocol RadioTransport: AnyObject {
    func send(_ bytes: [UInt8]) throws
    func receive(timeout: UInt32) throws -> [UInt8]
}

final class USBTransport: RadioTransport {
    private static let vendor: UInt16 = 0x0C26
    private static let product: UInt16 = 0x0018
    private let context: OpaquePointer
    private let handle: OpaquePointer

    static var detected: Bool {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["IOPropertyMatch"] = ["idVendor": Int(vendor), "idProduct": Int(product)]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    init() throws {
        var context: OpaquePointer?
        try Self.check(libusb_init(&context), "USBの初期化")
        guard let context else { throw R6Error("USBを初期化できませんでした。") }
        do {
            let handle = try Self.openCable(in: context)
            do {
                try Self.check(libusb_claim_interface(handle, 0), "ケーブルを開く操作")
                do {
                    try Self.configureUART(on: handle)
                } catch {
                    libusb_release_interface(handle, 0)
                    throw error
                }
            } catch {
                libusb_close(handle)
                throw error
            }
            self.context = context
            self.handle = handle
        } catch {
            libusb_exit(context)
            throw error
        }
    }

    deinit {
        libusb_release_interface(handle, 0)
        libusb_close(handle)
        libusb_exit(context)
    }

    private static func openCable(in context: OpaquePointer) throws -> OpaquePointer {
        var devices: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &devices)
        guard count >= 0, let devices else { throw R6Error("USB機器の一覧を取得できませんでした。") }
        defer { libusb_free_device_list(devices, 1) }

        let matches = (0..<count).compactMap { index -> OpaquePointer? in
            guard let device = devices[index] else { return nil }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0,
                  descriptor.idVendor == vendor, descriptor.idProduct == product else { return nil }
            return device
        }
        guard let device = matches.first else {
            throw R6Error("OPC-478UCが見つかりません。MacのUSB端子への接続を確認してください。")
        }
        guard matches.count == 1 else {
            throw R6Error("OPC-478UCが複数接続されています。使用する1本だけを接続してください。")
        }
        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        try check(libusb_get_active_config_descriptor(device, &config), "ケーブル情報の取得")
        guard let config else { throw R6Error("ケーブル情報が見つかりません。") }
        defer { libusb_free_config_descriptor(config) }
        let interface = config.pointee.interface.pointee.altsetting.pointee
        guard interface.bInterfaceNumber == 0, interface.bNumEndpoints == 3 else {
            throw R6Error("このOPC-478UCのタイプはアプリの対応範囲外です。")
        }
        var handle: OpaquePointer?
        try check(libusb_open(device, &handle), "ケーブルを開く操作")
        guard let handle else { throw R6Error("ケーブルを開けませんでした。") }
        return handle
    }

    private static func configureUART(on handle: OpaquePointer) throws {
        func control(_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16 = 0,
                     data: [UInt8] = []) throws -> [UInt8] {
            var bytes = data
            let length = UInt16(bytes.count)
            let count = bytes.withUnsafeMutableBufferPointer { buffer in
                libusb_control_transfer(handle, type, request, value, index, buffer.baseAddress, length, 500)
            }
            try check(count, "ケーブルの通信設定")
            guard count == length else { throw R6Error("ケーブルの通信設定を確認できませんでした。") }
            return bytes
        }

        // PL2303 HX/TA startup handshake. All requests here target the USB bridge.
        func readRegister(_ register: UInt16) throws -> UInt8 {
            try control(0xC0, 1, register, data: [0])[0]
        }
        func writeRegister(_ register: UInt16, _ value: UInt16) throws {
            _ = try control(0x40, 1, register, value)
        }
        _ = try readRegister(0x8080)
        _ = try readRegister(0x8484)
        try writeRegister(0x0404, 0)
        _ = try readRegister(0x8484)
        _ = try readRegister(0x8383)
        _ = try readRegister(0x8484)
        try writeRegister(0x0404, 1)
        _ = try readRegister(0x8484)
        _ = try readRegister(0x8383)
        try writeRegister(0, 1)
        try writeRegister(1, 0)
        try writeRegister(2, 0x44)
        try writeRegister(8, 0)
        try writeRegister(9, 0)
        try writeRegister(0, UInt16(readRegister(0x80) & 0x0F))

        // 9600 baud, 8 data bits, no parity, 1 stop bit.
        let lineCoding: [UInt8] = [0x80, 0x25, 0, 0, 0, 0, 8]
        _ = try control(0x21, 0x20, 0, data: lineCoding)
        guard try control(0xA1, 0x21, 0, data: Array(repeating: 0, count: 7)) == lineCoding else {
            throw R6Error("ケーブルを9600 bpsに設定できませんでした。")
        }
        _ = try control(0x21, 0x22, 3)
    }

    func send(_ bytes: [UInt8]) throws {
        var bytes = bytes
        let length = Int32(bytes.count)
        var transferred: Int32 = 0
        let result = bytes.withUnsafeMutableBufferPointer {
            libusb_bulk_transfer(handle, 0x02, $0.baseAddress, length, &transferred, 1500)
        }
        try Self.check(result, "データの送信")
        guard transferred == length else { throw R6Error("ケーブルへの送信が途中で止まりました。") }
    }

    func receive(timeout: UInt32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 256)
        let length = Int32(bytes.count)
        var transferred: Int32 = 0
        let result = bytes.withUnsafeMutableBufferPointer {
            libusb_bulk_transfer(handle, 0x83, $0.baseAddress, length, &transferred, timeout)
        }
        if result != LIBUSB_ERROR_TIMEOUT.rawValue {
            try Self.check(result, "データの受信")
        }
        return Array(bytes.prefix(Int(transferred)))
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        guard result >= 0 else {
            if result == LIBUSB_ERROR_NO_DEVICE.rawValue {
                throw R6Error("通信中にOPC-478UCの接続が切れました。")
            }
            if result == LIBUSB_ERROR_BUSY.rawValue || result == LIBUSB_ERROR_ACCESS.rawValue {
                throw R6Error("OPC-478UCを開けません。他の無線機ソフトを閉じて、ケーブルをつなぎ直してください。")
            }
            throw R6Error("\(operation)に失敗しました（\(String(cString: libusb_error_name(result)))）。")
        }
    }
}
