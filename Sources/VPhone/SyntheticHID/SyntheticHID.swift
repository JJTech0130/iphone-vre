// A synthetic USB HID device that delivers arbitrary fixed-size HID reports.
// Build descriptors with SyntheticHID.Descriptors or supply your own.

import Foundation

// MARK: - SyntheticHID

/// A synthetic USB HID device backed by SyntheticIOUSBDevice.
/// Inject reports with `sendReport(_:)` / `sendReportAndRelease(_:)`.
open class SyntheticHID: SyntheticIOUSBDevice {

    private var currentReportData: [UInt8]
    private let emptyReport: [UInt8]

    // MARK: Init

    /// - Parameters:
    ///   - reportDescriptor:    Raw HID report descriptor bytes.
    ///   - reportSize:          Size (in bytes) of a single input report.
    ///   - vendorID:            USB vendor ID (little-endian). Default: Apple (0x05AC).
    ///   - productID:           USB product ID (little-endian). Default: 0x0001.
    ///   - manufacturer:        Manufacturer string.
    ///   - product:             Product string.
    ///   - interfaceSubClass:   bInterfaceSubClass (0x01 = Boot Interface, 0x00 = none).
    ///   - interfaceProtocol:   bInterfaceProtocol (0x01 = Keyboard, 0x02 = Mouse, 0x00 = none).
    public init(reportDescriptor: [UInt8],
                reportSize: Int,
                vendorID: UInt16 = 0x05AC,
                productID: UInt16 = 0x0001,
                manufacturer: String = "Apple Inc.",
                product: String = "Virtual HID Device",
                interfaceSubClass: UInt8 = 0x01,
                interfaceProtocol: UInt8 = 0x01) {
        emptyReport = [UInt8](repeating: 0, count: reportSize)
        currentReportData = emptyReport

        let device = Self.makeDeviceDescriptor(vendorID: vendorID, productID: productID)
        let config = Self.makeConfigDescriptor(hidReportLen: reportDescriptor.count,
                                               subClass: interfaceSubClass,
                                               protocol_: interfaceProtocol)
        let descs  = USBDeviceDescriptors(device: device, configuration: config,
                                          hidReport: reportDescriptor,
                                          manufacturer: manufacturer, product: product)
        super.init(descriptors: descs)
    }

    // MARK: Report injection

    /// Set the report that will be returned on the next interrupt IN poll.
    public func sendReport(_ bytes: [UInt8]) {
        currentReportData = bytes
    }

    /// Reset the current report to all zeros.
    public func clearReport() {
        currentReportData = emptyReport
    }

    // MARK: SyntheticIOUSBDevice overrides

    open override func interruptINData(maxLength: Int) -> [UInt8] {
        Array(currentReportData.prefix(maxLength))
    }

    open override func getReport(maxLength: Int) -> [UInt8] {
        Array(emptyReport.prefix(maxLength))
    }

    // MARK: Descriptor builders

    private static func makeDeviceDescriptor(vendorID: UInt16, productID: UInt16) -> [UInt8] {
        [
            18,                                          // bLength
            0x01,                                        // bDescriptorType: DEVICE
            0x00, 0x02,                                  // bcdUSB: USB 2.0
            0x00,                                        // bDeviceClass: defined by interface
            0x00,                                        // bDeviceSubClass
            0x00,                                        // bDeviceProtocol
            8,                                           // bMaxPacketSize0
            UInt8(vendorID  & 0xFF), UInt8(vendorID  >> 8),
            UInt8(productID & 0xFF), UInt8(productID >> 8),
            0x00, 0x01,                                  // bcdDevice: 1.00
            0x01,                                        // iManufacturer
            0x02,                                        // iProduct
            0x00,                                        // iSerialNumber: none
            0x01,                                        // bNumConfigurations
        ]
    }

    /// Builds a standard single-interface HID configuration descriptor
    /// (Config 9B + Interface 9B + HID 9B + EP 7B = 34B total).
    private static func makeConfigDescriptor(hidReportLen: Int,
                                             subClass: UInt8 = 0x01,
                                             protocol_: UInt8 = 0x01) -> [UInt8] {
        let lo = UInt8(hidReportLen & 0xFF)
        let hi = UInt8((hidReportLen >> 8) & 0xFF)
        return [
            // Configuration descriptor (9 bytes)
            9, 0x02, 34, 0,     // bLength, bDescriptorType, wTotalLength LE
            0x01,               // bNumInterfaces
            0x01,               // bConfigurationValue
            0x00,               // iConfiguration
            0xA0,               // bmAttributes: bus powered + remote wakeup
            50,                 // bMaxPower: 100 mA (2 mA units)

            // Interface descriptor (9 bytes)
            9, 0x04,            // bLength, bDescriptorType: INTERFACE
            0x00, 0x00,         // bInterfaceNumber, bAlternateSetting
            0x01,               // bNumEndpoints
            0x03,               // bInterfaceClass: HID
            subClass,           // bInterfaceSubClass
            protocol_,          // bInterfaceProtocol
            0x00,               // iInterface

            // HID descriptor (9 bytes)
            9, 0x21,            // bLength, bDescriptorType: HID
            0x11, 0x01,         // bcdHID: 1.11
            0x00,               // bCountryCode
            0x01,               // bNumDescriptors
            0x22,               // bDescriptorType[0]: Report
            lo, hi,             // wDescriptorLength[0]

            // Endpoint descriptor (7 bytes) — EP1 IN, Interrupt
            7, 0x05,            // bLength, bDescriptorType: ENDPOINT
            0x81,               // bEndpointAddress: IN EP1
            0x03,               // bmAttributes: Interrupt
            8, 0,               // wMaxPacketSize: 8 bytes LE
            10,                 // bInterval: 10 ms
        ]
    }
}
