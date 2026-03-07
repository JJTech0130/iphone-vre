// Generic synthetic USB device backed by IOUSBHostControllerInterface.
// Subclass and override `interruptINData(maxLength:)` and `getReport(maxLength:)`
// to deliver custom data to the host.
//
// Entitlement required: com.apple.developer.usb.host-controller-interface

import Foundation
import IOUSBHost

// MARK: - USB descriptor bundle

public struct USBDeviceDescriptors {
    public let device: [UInt8]
    public let configuration: [UInt8]
    public let hidReport: [UInt8]
    public let manufacturer: String
    public let product: String

    public init(
        device: [UInt8], configuration: [UInt8], hidReport: [UInt8],
        manufacturer: String, product: String
    ) {
        self.device = device
        self.configuration = configuration
        self.hidReport = hidReport
        self.manufacturer = manufacturer
        self.product = product
    }
}

// MARK: - USB / HID request constants

private let kUSBReqGetDescriptor: UInt8 = 0x06
private let kUSBReqGetConfig: UInt8 = 0x08
private let kUSBReqGetInterface: UInt8 = 0x0A
private let kUSBDescDevice: UInt8 = 0x01
private let kUSBDescConfig: UInt8 = 0x02
private let kUSBDescString: UInt8 = 0x03
private let kHIDReqGetDescriptor: UInt8 = 0x06
private let kHIDDescHID: UInt8 = 0x21
private let kHIDDescReport: UInt8 = 0x22

private let kMsgTypeMask: UInt32 = 0x3F
private let kMsgValid: UInt32 = (1 << 15)

// MARK: - SyntheticIOUSBDevice

/// A generic synthetic USB 2.0 full-speed device presented via IOUSBHostControllerInterface.
/// Descriptors are supplied at init time. Subclass to customise data delivery.
open class SyntheticIOUSBDevice: NSObject {

    // MARK: Properties

    public let descriptors: USBDeviceDescriptors

    private var controller: IOUSBHostControllerInterface?
    private var deviceSMs: [Int: IOUSBHostCIDeviceStateMachine] = [:]
    private var endpointSMs: [Int: IOUSBHostCIEndpointStateMachine] = [:]
    private var frameNumber: UInt64 = 0
    private var portSM: IOUSBHostCIPortStateMachine?
    private var deviceConnected = false
    private var pendingResponse: Data?

    private let string0: [UInt8] = [4, 0x03, 0x09, 0x04]  // English (United States) language ID
    private let stringManuf: [UInt8]
    private let stringProd: [UInt8]

    // MARK: Init

    public init(descriptors: USBDeviceDescriptors) {
        self.descriptors = descriptors
        self.stringManuf = Self.makeStringDescriptor(descriptors.manufacturer)
        self.stringProd = Self.makeStringDescriptor(descriptors.product)
        super.init()
    }

    // MARK: Override points

    /// Called each time the host polls the interrupt IN endpoint (EP 0x81).
    /// Return the bytes to deliver; the result is clamped to `maxLength`.
    open func interruptINData(maxLength: Int) -> [UInt8] { [] }

    /// Called for a HID GET_REPORT class request (bmRequestType 0xA1).
    open func getReport(maxLength: Int) -> [UInt8] { [] }

    // MARK: Start / Stop

    public func start() throws {
        var err: NSError?
        let ci = IOUSBHostControllerInterface(
            __capabilities: buildCapabilities(),
            queue: nil,
            interruptRateHz: 0,
            error: &err,
            commandHandler: { [weak self] ci, cmd in self?.handleCommand(ci, cmd) },
            doorbellHandler: { [weak self] ci, db, n in self?.handleDoorbells(ci, db, n) },
            interestHandler: nil)

        if let e = err, e.code != 0 { throw e }
        guard let ci else {
            throw NSError(
                domain: "SyntheticIOUSBDevice", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create IOUSBHostControllerInterface"
                ])
        }
        controller = ci
        print("[\(typeName)] Controller created — UUID: \(ci.uuid.uuidString)")
    }

    public func stop() {
        controller?.destroy()
        controller = nil
        print("[\(typeName)] Stopped.")
    }

    private var typeName: String { String(describing: type(of: self)) }

    // MARK: Capabilities

    private func buildCapabilities() -> Data {
        var ctlCap = IOUSBHostCIMessage()
        ctlCap.control =
            UInt32(IOUSBHostCIMessageTypeControllerCapabilities.rawValue)
            | (1 << 14)  // NoResponse
            | (1 << 15)  // Valid
            | (1 << 16)  // PortCount = 1
        ctlCap.data0 = (1 << 0) | (2 << 4)  // CommandTimeoutThreshold=2s, ConnectionLatency=4ms

        var portCap = IOUSBHostCIMessage()
        portCap.control =
            UInt32(IOUSBHostCIMessageTypePortCapabilities.rawValue)
            | (1 << 14)  // NoResponse
            | (1 << 15)  // Valid
            | (1 << 16)  // PortNumber = 1
            | (0 << 24)  // ConnectorType = TypeA
        portCap.data0 = UInt32(500 / 8)  // MaxPower: 500 mA in 8 mA units

        var data = Data(bytes: &ctlCap, count: MemoryLayout<IOUSBHostCIMessage>.size)
        data.append(Data(bytes: &portCap, count: MemoryLayout<IOUSBHostCIMessage>.size))
        return data
    }

    // MARK: Command handler

    private func handleCommand(_ ci: IOUSBHostControllerInterface, _ cmdIn: IOUSBHostCIMessage) {
        var cmd = cmdIn
        let rawType = cmd.control & kMsgTypeMask
        let msgType = IOUSBHostCIMessageType(rawValue: rawType)
        let name =
            IOUSBHostCIMessageTypeToString(msgType).flatMap { String(cString: $0) }
            ?? "0x\(String(format: "%02X", rawType))"
        print("[\(typeName)] CMD \(name)")

        do {
            switch msgType {

            // ── Controller ────────────────────────────────────────────────
            case IOUSBHostCIMessageTypeControllerPowerOn,
                IOUSBHostCIMessageTypeControllerPowerOff,
                IOUSBHostCIMessageTypeControllerStart,
                IOUSBHostCIMessageTypeControllerPause:
                try ci.controllerStateMachine.respond(
                    toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)

            // ── Port ──────────────────────────────────────────────────────
            case IOUSBHostCIMessageTypePortPowerOn,
                IOUSBHostCIMessageTypePortPowerOff,
                IOUSBHostCIMessageTypePortResume,
                IOUSBHostCIMessageTypePortSuspend,
                IOUSBHostCIMessageTypePortReset,
                IOUSBHostCIMessageTypePortDisable,
                IOUSBHostCIMessageTypePortStatus:
                var portErr: NSError?
                let psm = ci.getPortStateMachine(forCommand: &cmd, error: &portErr)
                if portErr == nil || portErr!.code == 0 {
                    portSM = psm
                    try psm.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)
                    if msgType == IOUSBHostCIMessageTypePortPowerOn {
                        psm.powered = true
                        if !deviceConnected {
                            deviceConnected = true
                            psm.connected = true
                            try psm.updateLinkState(
                                IOUSBHostCILinkStateU0,
                                speed: IOUSBHostCIDeviceSpeedFull,
                                inhibitLinkStateChange: false)
                            print("[\(typeName)] Port 1: device connected (full-speed)")
                        }
                    } else if msgType == IOUSBHostCIMessageTypePortReset {
                        try psm.updateLinkState(
                            IOUSBHostCILinkStateU0,
                            speed: IOUSBHostCIDeviceSpeedFull,
                            inhibitLinkStateChange: false)
                    }
                } else if let e = portErr {
                    print("[\(typeName)] getPortStateMachine: \(e)")
                }

            // ── Device ────────────────────────────────────────────────────
            case IOUSBHostCIMessageTypeDeviceCreate:
                let dsm = try IOUSBHostCIDeviceStateMachine(__interface: ci, command: &cmd)
                let addr = 1
                try dsm.respond(
                    toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess, deviceAddress: addr)
                deviceSMs[addr] = dsm
                print("[\(typeName)] Device at address \(addr)")

            case IOUSBHostCIMessageTypeDeviceDestroy,
                IOUSBHostCIMessageTypeDeviceStart,
                IOUSBHostCIMessageTypeDevicePause,
                IOUSBHostCIMessageTypeDeviceUpdate:
                let devAddr = Int(cmd.data0 & 0xFF)
                if let dsm = deviceSMs[devAddr] {
                    try dsm.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)
                    if msgType == IOUSBHostCIMessageTypeDeviceDestroy {
                        deviceSMs.removeValue(forKey: devAddr)
                    }
                }

            // ── Endpoint ──────────────────────────────────────────────────
            case IOUSBHostCIMessageTypeEndpointCreate:
                let esm = try IOUSBHostCIEndpointStateMachine(__interface: ci, command: &cmd)
                try esm.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)
                let key = (esm.deviceAddress << 8) | esm.endpointAddress
                endpointSMs[key] = esm
                print(
                    "[\(typeName)] Endpoint device=\(esm.deviceAddress) ep=0x\(String(format: "%02X", esm.endpointAddress))"
                )

            case IOUSBHostCIMessageTypeEndpointDestroy,
                IOUSBHostCIMessageTypeEndpointPause,
                IOUSBHostCIMessageTypeEndpointUpdate,
                IOUSBHostCIMessageTypeEndpointReset,
                IOUSBHostCIMessageTypeEndpointSetNextTransfer:
                let devAddr = Int(cmd.data0 & 0xFF)
                let epAddr = Int((cmd.data0 >> 8) & 0xFF)
                let key = (devAddr << 8) | epAddr
                if let esm = endpointSMs[key] {
                    try esm.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)
                    if msgType == IOUSBHostCIMessageTypeEndpointDestroy {
                        endpointSMs.removeValue(forKey: key)
                    }
                }

            default:
                print("[\(typeName)] Unhandled 0x\(String(format: "%02X", rawType))")
            }
        } catch {
            print("[\(typeName)] handleCommand error: \(error)")
        }
    }

    // MARK: Doorbell handler

    private func handleDoorbells(
        _ ci: IOUSBHostControllerInterface,
        _ doorbells: UnsafePointer<IOUSBHostCIDoorbell>,
        _ count: UInt32
    ) {
        for i in 0..<Int(count) {
            let db = doorbells[i]
            let devAddr = Int(db & 0xFF)
            let epAddr = Int((db >> 8) & 0xFF)
            let key = (devAddr << 8) | epAddr
            guard let esm = endpointSMs[key] else { continue }
            do {
                try esm.processDoorbell(db)
                try processTransfers(for: esm)
            } catch {
                print(
                    "[\(typeName)] Doorbell ep=0x\(String(format: "%02X", epAddr)) error: \(error)")
            }
        }
    }

    // MARK: Transfer processing

    private func processTransfers(for esm: IOUSBHostCIEndpointStateMachine) throws {
        while esm.endpointState == IOUSBHostCIEndpointStateActive {
            let xfer = esm.currentTransferMessage
            guard (xfer.pointee.control & kMsgValid) != 0 else { break }

            switch IOUSBHostCIMessageType(rawValue: xfer.pointee.control & kMsgTypeMask) {
            case IOUSBHostCIMessageTypeSetupTransfer:
                handleSetupTransfer(esm: esm, xfer: xfer)
            case IOUSBHostCIMessageTypeNormalTransfer:
                try handleNormalTransfer(esm: esm, xfer: xfer)
            case IOUSBHostCIMessageTypeStatusTransfer:
                try esm.enqueueTransferCompletion(
                    for: xfer,
                    status: IOUSBHostCIMessageStatusSuccess,
                    transferLength: 0)
            default:
                return  // non-data message — wait for next doorbell
            }
        }
    }

    private func handleSetupTransfer(
        esm: IOUSBHostCIEndpointStateMachine,
        xfer: UnsafePointer<IOUSBHostCIMessage>
    ) {
        let d1 = xfer.pointee.data1
        let bmRequestType = UInt8((d1 >> 0) & 0xFF)
        let bRequest = UInt8((d1 >> 8) & 0xFF)
        let wValue = UInt16((d1 >> 16) & 0xFFFF)
        let wLength = UInt16((d1 >> 48) & 0xFFFF)
        let descType = UInt8((wValue >> 8) & 0xFF)
        let descIndex = UInt8(wValue & 0xFF)

        print(
            "[\(typeName)] SETUP bmRT=0x\(String(format: "%02X", bmRequestType)) bReq=0x\(String(format: "%02X", bRequest)) wVal=0x\(String(format: "%04X", wValue)) wLen=\(wLength)"
        )

        pendingResponse = resolveControlRequest(
            bmRequestType: bmRequestType, bRequest: bRequest,
            descType: descType, descIndex: descIndex, wLength: wLength)

        do {
            try esm.enqueueTransferCompletion(
                for: xfer,
                status: IOUSBHostCIMessageStatusSuccess,
                transferLength: 0)
        } catch {
            print("[\(typeName)] Setup ACK error: \(error)")
        }
    }

    private func handleNormalTransfer(
        esm: IOUSBHostCIEndpointStateMachine,
        xfer: UnsafePointer<IOUSBHostCIMessage>
    ) throws {
        if esm.endpointAddress == 0x81 {
            // Interrupt IN — deliver subclass data
            let maxLen = Int(xfer.pointee.data0 & 0x0FFF_FFFF)
            let bytes = interruptINData(maxLength: maxLen)
            let n = min(bytes.count, maxLen)
            if let buf = UnsafeMutableRawPointer(bitPattern: UInt(xfer.pointee.data1)) {
                buf.copyMemory(from: bytes, byteCount: n)
            }
            try esm.enqueueTransferCompletion(
                for: xfer,
                status: IOUSBHostCIMessageStatusSuccess,
                transferLength: n)
        } else {
            // EP0 data IN phase — fill from pending control response
            let maxLen = Int(xfer.pointee.data0 & 0x0FFF_FFFF)
            var written = 0
            if let resp = pendingResponse, !resp.isEmpty,
                let buf = UnsafeMutableRawPointer(bitPattern: UInt(xfer.pointee.data1))
            {
                let n = min(resp.count, maxLen)
                resp.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: n) }
                written = n
                pendingResponse = nil
            }
            try esm.enqueueTransferCompletion(
                for: xfer,
                status: IOUSBHostCIMessageStatusSuccess,
                transferLength: written)
        }
    }

    // MARK: Control request dispatch

    private func resolveControlRequest(
        bmRequestType: UInt8, bRequest: UInt8,
        descType: UInt8, descIndex: UInt8,
        wLength: UInt16
    ) -> Data? {
        switch bmRequestType {
        case 0x80:  // Standard Device → Host
            switch bRequest {
            case kUSBReqGetDescriptor:
                switch descType {
                case kUSBDescDevice: return prefix(descriptors.device, wLength)
                case kUSBDescConfig: return prefix(descriptors.configuration, wLength)
                case kUSBDescString:
                    switch descIndex {
                    case 0: return prefix(string0, wLength)
                    case 1: return prefix(stringManuf, wLength)
                    case 2: return prefix(stringProd, wLength)
                    default: return nil
                    }
                default: return nil
                }
            case kUSBReqGetConfig: return Data([1])
            default: return Data()
            }

        case 0x81:  // Standard Interface → Host
            switch bRequest {
            case kUSBReqGetInterface: return Data([0])
            case kHIDReqGetDescriptor:
                switch descType {
                case kHIDDescReport: return prefix(descriptors.hidReport, wLength)
                case kHIDDescHID:
                    // HID descriptor sits at bytes [18 ... 26] of the config blob
                    // (after 9-byte config + 9-byte interface descriptors)
                    let start = 18
                    let end = 27
                    guard descriptors.configuration.count >= end else { return nil }
                    return prefix(Array(descriptors.configuration[start..<end]), wLength)
                default: return nil
                }
            default: return nil
            }

        case 0x21:  // Class Host → Device (SET_PROTOCOL, SET_IDLE, SET_REPORT)
            return Data()

        case 0xA1:  // Class Device → Host (GET_REPORT)
            return Data(getReport(maxLength: Int(wLength)))

        default:
            return Data()
        }
    }

    // MARK: Helpers

    private func prefix(_ bytes: [UInt8], _ max: UInt16) -> Data {
        Data(bytes.prefix(Int(max)))
    }

    private static func makeStringDescriptor(_ text: String) -> [UInt8] {
        let utf16 = Array(text.utf16)
        var result: [UInt8] = [UInt8(2 + utf16.count * 2), 0x03]
        for cp in utf16 {
            result.append(UInt8(cp & 0xFF))
            result.append(UInt8(cp >> 8))
        }
        return result
    }
}
