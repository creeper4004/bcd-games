// SPDX-License-Identifier: GPL-3.0-only
// Compiled with the production BCDHDRReading value type by the host check.
var r = BCDHDRReading(enabled: true, measuring: true, prepared: true, valid: true,
    edr: true, linear: true, format: 115, appliedFlags: 9,
    samples: 2304, above: 123, peak: 1.7, headroom: 2)
precondition(r.confirmed && r.title == "Game frame contains an HDR signal")
r.appliedFlags = 11
precondition(r.title == "HDR test pattern confirmed")
r.appliedFlags = 8
precondition(!r.confirmed && r.title == "SDR comparison")
r.appliedFlags = 9
for change: (inout BCDHDRReading) -> Void in [
    { $0.valid = false }, { $0.prepared = false }, { $0.measuring = false },
    { $0.edr = false }, { $0.linear = false }, { $0.format = 80 },
    { $0.samples = 0 }, { $0.above = 0 }, { $0.invalid = 1 },
    { $0.peak = 1 }, { $0.headroom = 1 }, { $0.error = 1 }
] {
    var missing = r; change(&missing); precondition(!missing.confirmed)
}
r.above = 0; r.peak = 1
precondition(r.title == "No HDR highlights in sampled pixels")
r.prepared = false
precondition(r.title == "Start this game with Auto HDR enabled")
print("PASS: HDR evidence UI requires measured game pixels, float/linear/EDR output and display headroom; distinguishes pattern and SDR")
