import Dynamic
import Foundation
import IOKit
import Virtualization

let kFakeKeyboardVendorID  = 0x05AC
let kFakeKeyboardProductID = 0x0001
//let kFakeKeyboardVendorID = 0x1050
//let kFakeKeyboardProductID = 0x0407

extension VPhoneVM {
    /// Waits for the fake keyboard to appear in IOKit, authorizes it,
    /// and passes it through to the guest via private Virtualization API.
    @MainActor
    func attachFakeKeyboardToGuest() async {
        guard let controller = virtualMachine.usbControllers.first else {
            print("[vphone] USB passthrough: no USB controller configured")
            return
        }

        print("[vphone] USB passthrough: waiting for fake keyboard IOKit service…")
        guard let service = await pollForUSBService(vendor: kFakeKeyboardVendorID,
                                                    product: kFakeKeyboardProductID) else {
            print("[vphone] USB passthrough: timed out — dumping all USB devices in IOKit:")
            //dumpUSBDevices()
            return
        }
        defer { IOObjectRelease(service) }
        print(String(format: "[vphone] USB passthrough: found service 0x%x", service))

        // // Authorize for capture
        // let kr = IOServiceAuthorize(service, IOOptionBits(kIOServiceInteractionAllowed))
        // if kr != kIOReturnSuccess {
        //     let errStr = String(cString: mach_error_string(kr))
        //     print(String(format: "[vphone] IOServiceAuthorize failed: 0x%x (%@)", kr, errStr))
        // }

        // _VZIOUSBHostPassthroughDeviceConfiguration
        var initErr: NSError?
        let deviceConfig = Dynamic._VZIOUSBHostPassthroughDeviceConfiguration
            .initWithService(service, error: &initErr).asObject
        guard let deviceConfig = deviceConfig as? VZUSBDeviceConfiguration else {
            print("[vphone] Failed to create _VZIOUSBHostPassthroughDeviceConfiguration: \(initErr?.localizedDescription ?? "unknown error")")
            return
        }

        let device = Dynamic._VZIOUSBHostPassthroughDevice
            .initWithConfiguration(deviceConfig, error: &initErr).asObject
        guard let device = device as? VZUSBDevice else {
            print("[vphone] Failed to create _VZIOUSBHostPassthroughDevice: \(initErr?.localizedDescription ?? "unknown error")")
            return
        }

        // Attach to the running VM
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
            print("[vphone] Fake keyboard attached to guest VM via passthrough")
        } catch {
            print("[vphone] Failed to attach fake keyboard to guest: \(error)")
        }
    }

    private func pollForUSBService(vendor: Int, product: Int,
                                   timeout: TimeInterval = 10) async -> io_service_t? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let svc = lookupUSBService(vendor: vendor, product: product) { return svc }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        return nil
    }

    private func lookupUSBService(vendor: Int, product: Int) -> io_service_t? {
        // Try both new and old IOKit USB class names
        for className in ["IOUSBHostDevice"] {
            let matching = IOServiceMatching(className) as NSMutableDictionary
            matching["idVendor"]  = vendor
            matching["idProduct"] = product
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if svc != IO_OBJECT_NULL {
                print("[vphone] lookupUSBService: found via class '\(className)'")
                return svc
            }
        }
        return nil
    }
}
