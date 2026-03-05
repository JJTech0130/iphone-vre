// USB and HID descriptor bytes for a boot-protocol keyboard.
// Reference: USB HID 1.11 spec, USB 2.0 spec.

import Foundation

// MARK: - HID Report Descriptor
// Standard 8-byte boot-protocol keyboard report:
//   Byte 0: modifier keys bitmask
//   Byte 1: reserved (0x00)
//   Bytes 2-7: up to 6 simultaneous keycodes
let hidReportDescriptor: [UInt8] = [
    0x05, 0x01,  // Usage Page (Generic Desktop)
    0x09, 0x06,  // Usage (Keyboard)
    0xA1, 0x01,  // Collection (Application)
    // Modifier keys (8 bits)
    0x05, 0x07,  //   Usage Page (Key Codes)
    0x19, 0xE0,  //   Usage Minimum (224 = Left Control)
    0x29, 0xE7,  //   Usage Maximum (231 = Right GUI)
    0x15, 0x00,  //   Logical Minimum (0)
    0x25, 0x01,  //   Logical Maximum (1)
    0x75, 0x01,  //   Report Size (1 bit)
    0x95, 0x08,  //   Report Count (8)
    0x81, 0x02,  //   Input (Data, Variable, Absolute)
    // Reserved byte
    0x95, 0x01,  //   Report Count (1)
    0x75, 0x08,  //   Report Size (8 bits)
    0x81, 0x03,  //   Input (Constant)
    // LED output (5 bits + 3 padding)
    0x95, 0x05,  //   Report Count (5)
    0x75, 0x01,  //   Report Size (1 bit)
    0x05, 0x08,  //   Usage Page (LEDs)
    0x19, 0x01,  //   Usage Minimum (Num Lock)
    0x29, 0x05,  //   Usage Maximum (Kana)
    0x91, 0x02,  //   Output (Data, Variable, Absolute)
    0x95, 0x01,  //   Report Count (1)
    0x75, 0x03,  //   Report Size (3 bits)
    0x91, 0x03,  //   Output (Constant) - padding
    // Keycodes (6 x 8 bits)
    0x95, 0x06,  //   Report Count (6)
    0x75, 0x08,  //   Report Size (8 bits)
    0x15, 0x00,  //   Logical Minimum (0)
    0x25, 0x65,  //   Logical Maximum (101)
    0x05, 0x07,  //   Usage Page (Key Codes)
    0x19, 0x00,  //   Usage Minimum (0)
    0x29, 0x65,  //   Usage Maximum (101)
    0x81, 0x00,  //   Input (Data, Array)
    0xC0,        // End Collection
]

// MARK: - USB Descriptors

/// Device descriptor (18 bytes)
let usbDeviceDescriptor: [UInt8] = [
    18,           // bLength
    0x01,         // bDescriptorType: DEVICE
    0x00, 0x02,   // bcdUSB: USB 2.0
    0x00,         // bDeviceClass: defined by interface
    0x00,         // bDeviceSubClass
    0x00,         // bDeviceProtocol
    8,            // bMaxPacketSize0: 8 bytes (required for low-speed / HID)
    0xAC, 0x05,   // idVendor: Apple Inc. (0x05AC) — LE
    0x01, 0x00,   // idProduct: 0x0001 (synthetic keyboard)
    0x00, 0x01,   // bcdDevice: 1.00
    0x01,         // iManufacturer: string index 1
    0x02,         // iProduct: string index 2
    0x00,         // iSerialNumber: none
    0x01,         // bNumConfigurations: 1
]

// Configuration + Interface + HID + Endpoint descriptors (all in one block)
// Total length = 9 + 9 + 9 + 7 = 34
private let _hidDescLen = UInt8(hidReportDescriptor.count)
private let _hidDescLenLo = UInt8(hidReportDescriptor.count & 0xFF)
private let _hidDescLenHi = UInt8((hidReportDescriptor.count >> 8) & 0xFF)

let usbConfigurationDescriptor: [UInt8] = [
    // Configuration descriptor (9 bytes)
    9,            // bLength
    0x02,         // bDescriptorType: CONFIGURATION
    34, 0,        // wTotalLength: 34 bytes LE
    0x01,         // bNumInterfaces: 1
    0x01,         // bConfigurationValue: 1
    0x00,         // iConfiguration: none
    0xA0,         // bmAttributes: bus powered + remote wakeup
    50,           // bMaxPower: 100 mA (2 mA units)

    // Interface descriptor (9 bytes)
    9,            // bLength
    0x04,         // bDescriptorType: INTERFACE
    0x00,         // bInterfaceNumber: 0
    0x00,         // bAlternateSetting: 0
    0x01,         // bNumEndpoints: 1 (EP0 is not counted)
    0x03,         // bInterfaceClass: HID
    0x01,         // bInterfaceSubClass: Boot Interface
    0x01,         // bInterfaceProtocol: Keyboard
    0x00,         // iInterface: none

    // HID descriptor (9 bytes)
    9,            // bLength
    0x21,         // bDescriptorType: HID
    0x11, 0x01,   // bcdHID: HID 1.11
    0x00,         // bCountryCode: not localized
    0x01,         // bNumDescriptors: 1
    0x22,         // bDescriptorType[0]: Report
    _hidDescLenLo, _hidDescLenHi,  // wDescriptorLength[0]: length of report descriptor

    // Endpoint descriptor (7 bytes) — EP1 IN, Interrupt
    7,            // bLength
    0x05,         // bDescriptorType: ENDPOINT
    0x81,         // bEndpointAddress: IN EP1
    0x03,         // bmAttributes: Interrupt
    8, 0,         // wMaxPacketSize: 8 bytes LE
    10,           // bInterval: 10ms polling interval (full-speed)
]

// MARK: - String Descriptors

/// String descriptor 0: language list (English US = 0x0409)
let usbStringDescriptor0: [UInt8] = [4, 0x03, 0x09, 0x04]

func usbStringDescriptor(for text: String) -> [UInt8] {
    let utf16 = Array(text.utf16)
    var result: [UInt8] = [UInt8(2 + utf16.count * 2), 0x03]
    for cp in utf16 {
        result.append(UInt8(cp & 0xFF))
        result.append(UInt8(cp >> 8))
    }
    return result
}

let usbStringManufacturer = usbStringDescriptor(for: "Apple Inc.")
let usbStringProduct      = usbStringDescriptor(for: "Virtual HID Keyboard")

// MARK: - HID Keyboard Keycodes (USB HID usage table, page 0x07)

public enum HIDKeycode: UInt8 {
    case none = 0x00
    case a = 0x04, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case num1 = 0x1E, num2, num3, num4, num5, num6, num7, num8, num9, num0
    case returnKey = 0x28
    case escape   = 0x29
    case backspace = 0x2A
    case tab      = 0x2B
    case space    = 0x2C
    case capsLock = 0x39
    case f1 = 0x3A, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case up    = 0x52
    case down  = 0x51
    case left  = 0x50
    case right = 0x4F
}

public enum HIDModifier: UInt8 {
    case leftControl  = 0x01
    case leftShift    = 0x02
    case leftAlt      = 0x04
    case leftGUI      = 0x08
    case rightControl = 0x10
    case rightShift   = 0x20
    case rightAlt     = 0x40
    case rightGUI     = 0x80
}

/// An 8-byte HID keyboard report.
public struct HIDKeyboardReport: Sendable {
    public var modifiers: UInt8 = 0
    public var reserved: UInt8  = 0
    public var keys: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)

    public init() {}

    public static let empty = HIDKeyboardReport()

    public var bytes: [UInt8] {
        [modifiers, reserved,
         keys.0, keys.1, keys.2, keys.3, keys.4, keys.5]
    }
}
