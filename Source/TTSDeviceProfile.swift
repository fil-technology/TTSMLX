import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Coarse classification used to match a model to a device.
public enum TTSDeviceClass: String, Sendable, Hashable, Codable, CaseIterable {
    case iPhone
    case iPad
    case mac

    /// Rough ordering by available memory headroom — small index = tighter budget.
    public var memoryRank: Int {
        switch self {
        case .iPhone: return 0
        case .iPad:   return 1
        case .mac:    return 2
        }
    }
}

/// A snapshot of the host device used to gate model selection.
///
/// ``TTSDeviceProfile/current`` reads `UIDevice` / `ProcessInfo` at call time,
/// so it reflects the live device. Pass a manually constructed profile for
/// previews and tests.
public struct TTSDeviceProfile: Sendable, Hashable, Codable {
    public var deviceClass: TTSDeviceClass
    /// Physical RAM in MB. Reported by `ProcessInfo.processInfo.physicalMemory`.
    public var physicalMemoryMB: Int

    public init(deviceClass: TTSDeviceClass, physicalMemoryMB: Int) {
        self.deviceClass = deviceClass
        self.physicalMemoryMB = physicalMemoryMB
    }

    public static var current: TTSDeviceProfile {
        let memoryMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        return TTSDeviceProfile(deviceClass: Self.detectClass(), physicalMemoryMB: memoryMB)
    }

    private static func detectClass() -> TTSDeviceClass {
        #if os(macOS)
        return .mac
        #elseif canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return .iPad
        case .mac: return .mac
        default:   return .iPhone
        }
        #else
        return .iPhone
        #endif
    }
}
