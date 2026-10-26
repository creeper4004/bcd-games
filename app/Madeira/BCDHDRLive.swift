// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@MainActor enum BCDHDRLive {
    static let changed = Notification.Name("BCDHDRChanged")
    static func reading() -> BCDHDRReading {
        var raw = BCDHDRSnapshot()
        bcd_hdr_read(&raw)
        var r = BCDHDRReading()
        r.enabled = raw.flags & 1 != 0; r.pattern = raw.flags & 2 != 0; r.measuring = raw.flags & 4 != 0
        r.prepared = raw.prepared != 0; r.valid = raw.valid != 0
        r.edr = raw.edr != 0; r.linear = raw.linear != 0; r.format = raw.pixel_format
        r.appliedFlags = raw.applied_flags; r.samples = raw.samples; r.above = raw.above_sdr
        r.invalid = raw.invalid; r.error = raw.error
        r.peak = raw.peak.isFinite ? Double(raw.peak) : 0
        r.headroom = raw.headroom.isFinite ? max(1, Double(raw.headroom)) : 1
        return r
    }
    @discardableResult static func toggle(_ id: String, _ on: Bool) -> Bool {
        switch id {
        case "hdr.enabled": bcd_hdr_set_enabled(on ? 1 : 0)
        case "hdr.measure": bcd_hdr_set_probe(on ? 1 : 0)
        case "hdr.pattern": bcd_hdr_set_pattern(on ? 1 : 0)
        default: return false
        }
        return true
    }
}
