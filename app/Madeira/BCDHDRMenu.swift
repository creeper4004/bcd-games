// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Signal evidence, separate from the user's requested HDR setting. All values
/// are relative to SDR white; this is not a measurement of physical display nits.
struct BCDHDRReading: Equatable {
    var enabled = true
    var pattern = false
    var measuring = false
    var prepared = false
    var valid = false
    var edr = false
    var linear = false
    var format: UInt32 = 0
    var appliedFlags: UInt32 = 0
    var samples: UInt32 = 0
    var above: UInt32 = 0
    var invalid: UInt32 = 0
    var error: UInt32 = 0
    var peak: Double = 0
    var headroom: Double = 1

    var confirmed: Bool {
        error == 0 && valid && prepared && measuring && edr && linear && format == 115 && samples > 0
            && invalid == 0 && above > 0 && peak > 1.001 && headroom > 1 && appliedFlags & 1 != 0
    }
    var title: String {
        if !prepared { return "Start this game with Auto HDR enabled" }
        if !measuring { return enabled ? "HDR comparison ready" : "SDR comparison" }
        if error != 0 { return "HDR measurement unavailable" }
        if !valid { return "Waiting for a measured frame" }
        if invalid > 0 || samples == 0 { return "Invalid pixel samples" }
        if !edr || !linear || format != 115 { return "HDR output is not configured" }
        if appliedFlags & 1 == 0 { return "SDR comparison" }
        if confirmed { return appliedFlags & 2 != 0 ? "HDR test pattern confirmed" : "Game frame contains an HDR signal" }
        if above > 0 && headroom <= 1 { return "HDR signal; display headroom is 1×" }
        return "No HDR highlights in sampled pixels"
    }
    var detail: String {
        if !prepared { return "Enable Auto HDR in the game's Display settings before starting it. Live comparison needs the updated DXMT renderer; Direct3D 12 is not measured." }
        if !measuring { return "Switch between HDR and SDR without restarting. Both use the same output layer, so SDR white stays stable. This choice lasts for this session." }
        if error != 0 { return "The frame could not be sampled. Resume the game and check the log's [hdr-signal] lines." }
        if !valid { return "Resume the game to apply the change and measure its next frames. Old measurements are cleared when you change a control." }
        let percent = samples > 0 ? 100 * Double(above) / Double(samples) : 0
        let source = appliedFlags & 2 != 0 ? "Test pattern" : "Game drawable"
        return String(format: "Last measured %@ · sampled peak %.2f× SDR white · %.1f%% of %u samples above SDR · display headroom %.2f×. EDR %@, linear %@, float %@. Sparse samples can miss small highlights.",
                      source, peak, percent, samples, headroom, edr ? "on" : "off", linear ? "yes" : "no", format == 115 ? "yes" : "no")
    }
    var overlay: String {
        guard valid else { return title }
        return title + String(format: "\nPeak %.2f× · %u/%u samples > SDR · display %.2f×", peak, above, samples, headroom)
    }
}

enum BCDHDRMenu {
    static func section(_ reading: BCDHDRReading) -> BCDMenuSection {
        BCDMenuSection(id: "hdr", title: "HDR comparison & validation", rows: [
            BCDMenuRow(id: "hdr.enabled", title: "HDR view", detail: "Off shows the SDR reference. Applies when the game resumes; the output layer stays the same.",
                       kind: .toggle(reading.enabled), enabled: reading.prepared),
            BCDMenuRow(id: "hdr.measure", title: "Measure the game's HDR signal",
                       detail: "Shows a small readout over the game. Samples the actual game texture twice a second, before menus and touch controls are drawn.",
                       kind: .toggle(reading.measuring), enabled: reading.prepared),
            BCDMenuRow(id: "hdr.pattern", title: "Show HDR test pattern",
                       detail: "Temporarily replaces the game image with five gray bands: 0.18×, 1× SDR white, 1.25×, 1.5× and 2×. Limited by available headroom. Turn off to test gameplay again.",
                       kind: .toggle(reading.pattern), enabled: reading.prepared),
            BCDMenuRow(id: "hdr.signal", title: reading.title, detail: reading.detail,
                       kind: .note(reading.confirmed ? .good : .soft)),
        ])
    }
}

@MainActor final class BCDHDRFeed: ObservableObject {
    @Published var reading: BCDHDRReading
    init(_ reading: BCDHDRReading) { self.reading = reading }
}
struct BCDHDRSignalView: View {
    @ObservedObject var feed: BCDHDRFeed
    var body: some View {
        Text(feed.reading.overlay)
            .font(BCDStyle.label(11)).foregroundStyle(BCDStyle.text)
            .multilineTextAlignment(.center).padding(9)
            .background(BCDSessionStyle.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BCDStyle.stroke, lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(feed.reading.overlay)
    }
}
