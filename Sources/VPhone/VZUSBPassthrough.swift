import Dynamic
import Foundation
import IOKit
import Virtualization

enum PassthroughError: Error {
    case deviceNotFound(vendor: Int, product: Int)
    case failedToCreateDeviceConfig(underlyingError: Error?)
    case failedToCreateDevice(underlyingError: Error?)
    case failedToAttachDevice(underlyingError: Error)
}

/// Waits for a USB device to appear in IOKit and attaches it to the given USB controller.
@MainActor
func attachUSBDeviceToController(
    _ controller: VZUSBController,
    vendor: Int,
    product: Int,
) async throws {
    // Patch buggy VZIOUSBHostPassthroughDevice behavior on Sequoia
    if #available(macOS 15, *), ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 {
        VZSequoiaSwizzle.install()
    }

    let label = String(format: "vendor=0x%04x product=0x%04x", vendor, product)

    // poll every 0.5s for the device to show up in IOKit, with a 10s timeout
    let deadline = Date().addingTimeInterval(10)
    var service: io_service_t?

    print("attachUSBDeviceToController: waiting for device with \(label) to appear in IOKit")

    repeat {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = vendor
        matching["idProduct"] = product

        let svc = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        if svc != IO_OBJECT_NULL {
            service = svc
            break
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
    } while Date() < deadline

    guard let service else {
        throw PassthroughError.deviceNotFound(vendor: vendor, product: product)
    }
    defer { IOObjectRelease(service) }

    print("attachUSBDeviceToController: found device with \(label) in IOKit, creating config")

    var initErr: NSError?
    let deviceConfig = Dynamic._VZIOUSBHostPassthroughDeviceConfiguration
        .initWithService(service, error: &initErr).asObject
    guard let deviceConfig = deviceConfig as? VZUSBDeviceConfiguration else {
        throw PassthroughError.failedToCreateDeviceConfig(underlyingError: initErr)
    }

    let device = Dynamic._VZIOUSBHostPassthroughDevice
        .initWithConfiguration(deviceConfig, error: &initErr).asObject
    guard let device = device as? VZUSBDevice else {
        throw PassthroughError.failedToCreateDevice(underlyingError: initErr)
    }

    print("attachUSBDeviceToController: attaching \(label) to VM")

    do {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            controller.attach(device: device) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        print("attachUSBDeviceToController: successfully attached \(label) to VM")
    } catch {
        throw PassthroughError.failedToAttachDevice(underlyingError: error)
    }
}
