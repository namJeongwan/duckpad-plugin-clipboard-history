import AppKit

/// A real table cell keeps text centered inside the native selection highlight.
@MainActor
final class SingleLineTableCell: NSTableCellView {
    private let thumbnail = NSImageView()
    private var labelLeading: NSLayoutConstraint!
    init() {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); textField = label
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyDown
        addSubview(thumbnail)
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 20),
            thumbnail.heightAnchor.constraint(equalToConstant: 20),
            labelLeading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    func configure(text: String, image: NSImage?) {
        textField?.stringValue = text; thumbnail.image = image
        thumbnail.isHidden = image == nil; labelLeading.constant = image == nil ? 8 : 36
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
