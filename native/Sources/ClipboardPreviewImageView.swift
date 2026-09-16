import AppKit

/// Preview pixels never participate in the panel's minimum-size calculation.
@MainActor final class ClipboardPreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
