import AppKit

/// A real table cell keeps text centered inside the native selection highlight.
@MainActor
final class SingleLineTableCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
