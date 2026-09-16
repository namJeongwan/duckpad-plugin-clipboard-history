import AppKit

/// Native buttons flow onto another line when the available width runs out.
@MainActor
final class WrappingButtonBar: NSView {
    private let buttons: [NSButton]
    private let spacing: CGFloat = 8
    init(buttons: [NSButton]) {
        self.buttons = buttons
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for button in buttons { button.translatesAutoresizingMaskIntoConstraints = true; addSubview(button) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: arrange(apply: false)) }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.width != newSize.width
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize(); needsLayout = true }
    }
    func refresh() { invalidateIntrinsicContentSize(); needsLayout = true }
    override func layout() { super.layout(); _ = arrange(apply: true) }
    private func arrange(apply: Bool) -> CGFloat {
        let available = max(1, bounds.width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.intrinsicContentSize
            let width = min(available, max(44, ceil(size.width)))
            let height = max(24, ceil(size.height))
            if x > 0 && x + width > available { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            if apply { button.frame = NSRect(x: x, y: y, width: width, height: height) }
            x += width + spacing; rowHeight = max(rowHeight, height)
        }
        return y + rowHeight
    }
}
