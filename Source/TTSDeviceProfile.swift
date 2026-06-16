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

    /// Default look-ahead window (in seconds of audio) for live streaming
    /// playback, scaled to the device's memory headroom. This bounds how far
    /// generation may run ahead of playback so reading a whole book never
    /// accumulates more than a few seconds of PCM in memory.
    ///
    /// Roughly: a 30 s window holds ~170 MB of 24 kHz mono float audio across
    /// the pipeline, so tighter-memory phones get a smaller window. These are
    /// conservative defaults; callers can override per call.
    public var recommendedLookAheadSeconds: Double {
        switch deviceClass {
        case .mac:
            return 45
        case .iPad:
            return physicalMemoryMB >= 6_000 ? 30 : 20
        case .iPhone:
            if physicalMemoryMB >= 8_000 { return 30 }
            if physicalMemoryMB >= 6_000 { return 24 }
            if physicalMemoryMB >= 4_000 { return 18 }
            return 12
        }
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
