import Foundation

/// Persistent identity for a physical display. CGDirectDisplayID is unstable
/// across reconnects/reboots, so we match on hardware attributes instead.
public struct DisplayFingerprint: Codable, Hashable, Sendable {
    public var vendorNumber: UInt32?
    public var modelNumber: UInt32?
    public var serialNumber: UInt32?
    /// NSScreen.localizedName at assignment time (also shown in the UI).
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        vendorNumber: UInt32? = nil,
        modelNumber: UInt32? = nil,
        serialNumber: UInt32? = nil,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Match quality against a connected display's fingerprint; higher wins.
    /// 0 = no plausible match. Vendor+model+serial is authoritative; name and
    /// pixel size break ties when serials are missing (common on projectors).
    public func matchScore(against other: DisplayFingerprint) -> Int {
        var score = 0
        if let v = vendorNumber, let ov = other.vendorNumber {
            if v != ov { return 0 }
            score += 4
        }
        if let m = modelNumber, let om = other.modelNumber {
            if m != om { return 0 }
            score += 4
        }
        if let s = serialNumber, let os = other.serialNumber, s != 0, os != 0 {
            score += s == os ? 8 : -6
        }
        if name == other.name { score += 3 }
        if pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight { score += 1 }
        return max(0, score)
    }
}
