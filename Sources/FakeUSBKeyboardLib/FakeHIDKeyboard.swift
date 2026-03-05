// FakeHIDKeyboard.swift
// Creates a synthetic USB HID keyboard via IOUSBHostControllerInterface.
// The virtual controller exposes one port with a full-speed HID keyboard.
// After the host enumerates it you can pass it through to a VM guest.
//
// Entitlement required: com.apple.developer.usb.host-controller-interface

import Foundation
import IOUSBHost

// MARK: - USB Standard constants
private let kUSBReqGetDescriptor: UInt8 = 0x06
private let kUSBReqSetAddress:    UInt8 = 0x05
private let kUSBReqSetConfig:     UInt8 = 0x09
private let kUSBReqGetConfig:     UInt8 = 0x08
private let kUSBReqGetInterface:  UInt8 = 0x0A
private let kUSBDescDevice:       UInt8 = 0x01
private let kUSBDescConfig:       UInt8 = 0x02
private let kUSBDescString:       UInt8 = 0x03
private let kHIDReqGetDescriptor: UInt8 = 0x06
private let kHIDDescHID:          UInt8 = 0x21
private let kHIDDescReport:       UInt8 = 0x22

// Message type is in bits 0-5 of the control field (IOUSBHostCIMessageControlTypePhase = 0).
private let kMsgTypeMask: UInt32 = 0x3F
// Valid bit is bit 15 (IOUSBHostCIMessageControlValid).
private let kMsgValid: UInt32 = (1 << 15)

// MARK: - FakeHIDKeyboard

/// Manages a synthetic USB 2.0 full-speed HID keyboard via IOUSBHostControllerInterface.
public final class FakeHIDKeyboard: NSObject {

    // MARK: - Properties

    private var controller: IOUSBHostControllerInterface?

    // Device state machines, keyed by device address
    private var deviceSMs: [Int: IOUSBHostCIDeviceStateMachine] = [:]

    // Endpoint state machines, keyed by (deviceAddress << 8 | endpointAddress)
    private var endpointSMs: [Int: IOUSBHostCIEndpointStateMachine] = [:]

    // Current HID report delivered on the next interrupt IN poll
    private var currentReport = HIDKeyboardReport.empty

    // Running frame counter for the controller
    private var frameNumber: UInt64 = 0
    private var frameTimer: DispatchSourceTimer?

    // Port state machine stored when we first get a port command
    private var portSM: IOUSBHostCIPortStateMachine?
    private var deviceConnected = false

    // Pending IN data for the current EP0 control transfer data phase
    private var pendingResponse: Data? = nil

    // MARK: - Start / Stop

    public override init() { super.init() }

    public func start() throws {
        var initErr: NSError?
        let ci = IOUSBHostControllerInterface(
            __capabilities: buildCapabilities(), // capabilities of this controller
            queue: nil, // use a default background queue for controller callbacks
            interruptRateHz: 0, // deliver all interrupts to the kernel immediately
            error: &initErr,
            // kernel driver sends commands like power on, reset, etc; we respond to those in the command handler callback
            commandHandler: { [weak self] ci, cmd in self?.handleCommand(ci, cmd) },
            // kernel driver sends doorbell messages to notify the us that transfer structures have been updated;
            //   we then loop through all pending transfers and handle them
            doorbellHandler: { [weak self] ci, doorbells, count in
                self?.handleDoorbells(ci, doorbells, count)
            },
            // used to process service state changes such as termination; we don't need that
            interestHandler: nil)

        if let e = initErr, e.code != 0 { throw e }
        guard let ci else {
            throw NSError(domain: "FakeHIDKeyboard", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create IOUSBHostControllerInterface"])
        }
        controller = ci
        print("[FakeHIDKeyboard] Controller created — UUID: \(ci.uuid.uuidString)")
    }

    public func stop() {
        frameTimer?.cancel()
        frameTimer = nil
        controller?.destroy()
        controller = nil
        print("[FakeHIDKeyboard] Stopped.")
    }

    // MARK: - Key injection

    /// Press and release a single key (blocks ~70ms).
    public func typeKey(_ keycode: HIDKeycode, modifiers: UInt8 = 0) {
        var report = HIDKeyboardReport()
        report.modifiers = modifiers
        report.keys.0 = keycode.rawValue
        currentReport = report
        Thread.sleep(forTimeInterval: 0.05)
        currentReport = HIDKeyboardReport.empty
        Thread.sleep(forTimeInterval: 0.02)
    }

    // MARK: - Capabilities

    private func buildCapabilities() -> Data {
        // Controller capabilities message:
        //   type=ControllerCapabilities (0x00) in bits 0-5
        //   NoResponse  = bit 14
        //   Valid       = bit 15
        //   PortCount=1 in bits 16-19
        var ctlCap = IOUSBHostCIMessage()
        ctlCap.control =
            UInt32(IOUSBHostCIMessageTypeControllerCapabilities.rawValue)
            | (1 << 14)   // NoResponse
            | (1 << 15)   // Valid
            | (1 << 16)   // PortCount = 1 (bits 16-19)
        // CommandTimeoutThreshold = 2^1 = 2s (bits 0-1), ConnectionLatency = 2^2 = 4ms (bits 4-7)
        ctlCap.data0 = (1 << 0) | (2 << 4)

        // Port 1 capabilities message:
        //   type=PortCapabilities (0x01) in bits 0-5
        //   PortNumber=1 in bits 16-19
        //   ConnectorType=0 (ACPI TypeA) in bits 24-31
        var portCap = IOUSBHostCIMessage()
        portCap.control =
            UInt32(IOUSBHostCIMessageTypePortCapabilities.rawValue)
            | (1 << 14)   // NoResponse
            | (1 << 15)   // Valid
            | (1 << 16)   // PortNumber = 1
            | (0 << 24)   // ConnectorType = 0 (TypeA)
        portCap.data0 = UInt32(500 / 8)  // MaxPower = 500 mA in 8mA units → 62

        var data = Data(bytes: &ctlCap,  count: MemoryLayout<IOUSBHostCIMessage>.size)
        data.append(Data(bytes: &portCap, count: MemoryLayout<IOUSBHostCIMessage>.size))
        return data
    }

    // MARK: - Command handler

    private func handleCommand(_ ci: IOUSBHostControllerInterface, _ cmdIn: IOUSBHostCIMessage) {
        var cmd = cmdIn  // mutable copy needed for inout parameters

        let rawType = cmd.control & kMsgTypeMask
        let msgType = IOUSBHostCIMessageType(rawValue: rawType)
        let name = IOUSBHostCIMessageTypeToString(msgType).flatMap { String(cString: $0) } ?? "0x\(String(format:"%02X",rawType))"
        print("[FakeHIDKeyboard] CMD \(name)")

        do {
            switch msgType {

            // ── Controller ────────────────────────────────────────────────
            case IOUSBHostCIMessageTypeControllerPowerOn,
                 IOUSBHostCIMessageTypeControllerPowerOff,
                 IOUSBHostCIMessageTypeControllerStart,
                 IOUSBHostCIMessageTypeControllerPause:
                try ci.controllerStateMachine.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)
                if msgType == IOUSBHostCIMessageTypeControllerStart {
                    //startFrameTimer()
                }

            case IOUSBHostCIMessageTypeControllerFrameNumber:
                try ci.controllerStateMachine.respond(
                    toCommand: &cmd,
                    status: IOUSBHostCIMessageStatusSuccess,
                    frame: frameNumber,
                    timestamp: mach_absolute_time())

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
                        // Connect the keyboard once the port is powered
                        if !deviceConnected {
                            deviceConnected = true
                            psm.connected = true
                            try psm.updateLinkState(IOUSBHostCILinkStateU0,
                                                    speed: IOUSBHostCIDeviceSpeedFull,
                                                    inhibitLinkStateChange: false)
                            print("[FakeHIDKeyboard] Port 1: keyboard connected (full-speed)")
                        }
                    } else if msgType == IOUSBHostCIMessageTypePortReset {
                        try psm.updateLinkState(IOUSBHostCILinkStateU0,
                                                speed: IOUSBHostCIDeviceSpeedFull,
                                                inhibitLinkStateChange: false)
                    }
                } else if let e = portErr {
            print("[FakeHIDKeyboard] getPortStateMachine: \(e)")
        }

            // ── Device ────────────────────────────────────────────────────
            case IOUSBHostCIMessageTypeDeviceCreate:
                let dsm = try IOUSBHostCIDeviceStateMachine(__interface: ci, command: &cmd)
                let addr = 1
                try dsm.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess, deviceAddress: addr)
                deviceSMs[addr] = dsm
                print("[FakeHIDKeyboard] Device at address \(addr)")

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
                print("[FakeHIDKeyboard] Endpoint device=\(esm.deviceAddress) ep=0x\(String(format:"%02X",esm.endpointAddress))")

            case IOUSBHostCIMessageTypeEndpointDestroy,
                 IOUSBHostCIMessageTypeEndpointPause,
                 IOUSBHostCIMessageTypeEndpointUpdate,
                 IOUSBHostCIMessageTypeEndpointReset,
                 IOUSBHostCIMessageTypeEndpointSetNextTransfer:
                let devAddr = Int(cmd.data0 & 0xFF)
                let epAddr  = Int((cmd.data0 >> 8) & 0xFF)
                let key = (devAddr << 8) | epAddr
                if let esm = endpointSMs[key] {
                    try esm.respond(toCommand: &cmd, status: IOUSBHostCIMessageStatusSuccess)
                    if msgType == IOUSBHostCIMessageTypeEndpointDestroy {
                        endpointSMs.removeValue(forKey: key)
                    }
                }

            default:
                print("[FakeHIDKeyboard] Unhandled 0x\(String(format:"%02X",rawType))")
            }
        } catch {
            print("[FakeHIDKeyboard] handleCommand error: \(error)")
        }
    }

    // MARK: - Doorbell handler

    private func handleDoorbells(_ ci: IOUSBHostControllerInterface,
                                  _ doorbells: UnsafePointer<IOUSBHostCIDoorbell>,
                                  _ count: UInt32) {
        for i in 0..<Int(count) {
            let db = doorbells[i]
            let devAddr = Int(db & 0xFF)
            let epAddr  = Int((db >> 8) & 0xFF)
            let key = (devAddr << 8) | epAddr
            guard let esm = endpointSMs[key] else { continue }
            do {
                try esm.processDoorbell(db)
                try processTransfers(for: esm)
            } catch {
                print("[FakeHIDKeyboard] Doorbell ep=0x\(String(format:"%02X",epAddr)) error: \(error)")
            }
        }
    }

    // MARK: - Transfer processing

    private func processTransfers(for esm: IOUSBHostCIEndpointStateMachine) throws {
        while esm.endpointState == IOUSBHostCIEndpointStateActive {
            let xfer = esm.currentTransferMessage
            guard (xfer.pointee.control & kMsgValid) != 0 else { break }

            let xferType = IOUSBHostCIMessageType(rawValue: xfer.pointee.control & kMsgTypeMask)

            switch xferType {
            case IOUSBHostCIMessageTypeSetupTransfer:
                handleSetupTransfer(esm: esm, xfer: xfer)

            case IOUSBHostCIMessageTypeNormalTransfer:
                try handleNormalTransfer(esm: esm, xfer: xfer)

            case IOUSBHostCIMessageTypeStatusTransfer:
                try esm.enqueueTransferCompletion(for: xfer,
                                                   status: IOUSBHostCIMessageStatusSuccess,
                                                   transferLength: 0)

            default:
                return  // Link or other non-data message — stop; next doorbell continues
            }
        }
    }

    private func handleSetupTransfer(esm: IOUSBHostCIEndpointStateMachine,
                                      xfer: UnsafePointer<IOUSBHostCIMessage>) {
        let d1 = xfer.pointee.data1
        let bmRequestType = UInt8((d1 >>  0) & 0xFF)
        let bRequest      = UInt8((d1 >>  8) & 0xFF)
        let wValue        = UInt16((d1 >> 16) & 0xFFFF)
        let wLength       = UInt16((d1 >> 48) & 0xFFFF)
        let descType  = UInt8((wValue >> 8) & 0xFF)
        let descIndex = UInt8(wValue & 0xFF)

        print("[FakeHIDKeyboard] SETUP bmRT=0x\(String(format:"%02X",bmRequestType)) bReq=0x\(String(format:"%02X",bRequest)) wVal=0x\(String(format:"%04X",wValue)) wLen=\(wLength)")

        pendingResponse = resolveControlRequest(
            bmRequestType: bmRequestType, bRequest: bRequest,
            descType: descType, descIndex: descIndex, wLength: wLength)

        do {
            try esm.enqueueTransferCompletion(for: xfer,
                                               status: IOUSBHostCIMessageStatusSuccess,
                                               transferLength: 0)
        } catch {
            print("[FakeHIDKeyboard] Setup ACK error: \(error)")
        }
    }

    private func handleNormalTransfer(esm: IOUSBHostCIEndpointStateMachine,
                                       xfer: UnsafePointer<IOUSBHostCIMessage>) throws {
        if esm.endpointAddress == 0x81 {
            // Interrupt IN — deliver current HID report
            let maxLen = Int(xfer.pointee.data0 & 0x0FFF_FFFF)
            let bytes = currentReport.bytes
            let n = min(bytes.count, maxLen)
            if let buf = UnsafeMutableRawPointer(bitPattern: UInt(xfer.pointee.data1)) {
                buf.copyMemory(from: bytes, byteCount: n)
            }
            try esm.enqueueTransferCompletion(for: xfer,
                                               status: IOUSBHostCIMessageStatusSuccess,
                                               transferLength: n)
        } else {
            // EP0 data IN phase — fill from pending response
            let maxLen = Int(xfer.pointee.data0 & 0x0FFF_FFFF)
            var written = 0
            if let resp = pendingResponse, !resp.isEmpty,
               let buf = UnsafeMutableRawPointer(bitPattern: UInt(xfer.pointee.data1)) {
                let n = min(resp.count, maxLen)
                resp.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: n) }
                written = n
                pendingResponse = nil
            }
            try esm.enqueueTransferCompletion(for: xfer,
                                               status: IOUSBHostCIMessageStatusSuccess,
                                               transferLength: written)
        }
    }

    // MARK: - Control request dispatch

    private func resolveControlRequest(bmRequestType: UInt8, bRequest: UInt8,
                                        descType: UInt8, descIndex: UInt8,
                                        wLength: UInt16) -> Data? {
        switch bmRequestType {
        case 0x80:  // Standard Device → Host
            switch bRequest {
            case kUSBReqGetDescriptor:
                switch descType {
                case kUSBDescDevice: return prefix(usbDeviceDescriptor, wLength)
                case kUSBDescConfig: return prefix(usbConfigurationDescriptor, wLength)
                case kUSBDescString:
                    switch descIndex {
                    case 0: return prefix(usbStringDescriptor0, wLength)
                    case 1: return prefix(usbStringManufacturer, wLength)
                    case 2: return prefix(usbStringProduct, wLength)
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
                case kHIDDescReport: return prefix(hidReportDescriptor, wLength)
                case kHIDDescHID:
                    let start = 9 + 9  // after Config + Interface
                    return prefix(Array(usbConfigurationDescriptor[start..<start+9]), wLength)
                default: return nil
                }
            default: return nil
            }

        case 0x21:  // Class Interface Host → Device (SET_PROTOCOL, SET_IDLE, SET_REPORT)
            return Data()

        case 0xA1:  // Class Interface Device → Host (GET_REPORT)
            return prefix(HIDKeyboardReport.empty.bytes, wLength)

        default:
            return Data()
        }
    }

    // MARK: - Frame timer

    private func startFrameTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 1000Hz = 1ms
        timer.schedule(deadline: .now() + 0.001, repeating: 0.001)
        timer.setEventHandler { [weak self] in
            guard let self, let ci = self.controller else { return }
            self.frameNumber += 1
            // do { try ci.controllerStateMachine.enqueueUpdatedFrame(
            //     self.frameNumber, timestamp: mach_absolute_time())
            // } catch {
            //     print("[FakeHIDKeyboard] Failed to enqueue frame update: \(error)")
            // }
        }
        timer.resume()
        frameTimer = timer
        print("[FakeHIDKeyboard] Frame timer started (1ms / USB frame)")
    }

    // MARK: - Helpers

    private func prefix(_ bytes: [UInt8], _ max: UInt16) -> Data {
        Data(bytes.prefix(Int(max)))
    }
}
