//
//  MachineID.swift
//
//
//  Created by John Cris Antor on 6/20/2026.
//

import Foundation
import IOKit

/// Provides a stable, hardware-derived machine identifier using IOKit's `IOPlatformUUID`.
///
/// This UUID is the sole identifier the license server binds licenses to.
/// It is consistent across reboots and OS reinstalls on the same hardware.
enum MachineID {
    /// The cached `IOPlatformUUID` for this machine, queried once at process start.
    static let platformUUID: String = {
        let matchingDict = IOServiceMatching("IOPlatformExpertDevice")
        let service: io_service_t
        if #available(macOS 12.0, *) {
            service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        } else {
            service = IOServiceGetMatchingService(kIOMasterPortDefault, matchingDict)
        }
        guard service != IO_OBJECT_NULL else {
            // This should never happen on real hardware, but fail loud if it does.
            fatalError("[Airway] Unable to find IOPlatformExpertDevice — cannot derive machine ID.")
        }
        defer { IOObjectRelease(service) }

        guard let uuidProperty = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            fatalError("[Airway] Unable to read IOPlatformUUID — cannot derive machine ID.")
        }

        return uuidProperty
    }()
}
