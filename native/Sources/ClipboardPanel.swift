import AppKit

@MainActor
final class ClipboardPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let heading = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let search = NSSearchField()
    private let table = ExtensionListTableView()
    private let preview = NSTextView()
    private let imagePreview = ClipboardPreviewImageView()
    private let previewScroll = NSScrollView()
    private var thumbnails: [String: NSImage] = [:]
    private let previewHeading = NSTextField(labelWithString: "")
    private let retentionLabel = NSTextField(labelWithString: "")
    private var catalog = L10n.catalog
    private var titleKey = "Clipboard History"
    private lazy var actionBar = WrappingButtonBar(buttons: [pasteButton, nextButton, pinButton, deleteButton, clearButton])
    private func localized(_ key: String) -> String { catalog.text(key) }
    private var previewID: String?
    private let status = NSTextField(labelWithString: "")
    private let pasteButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let retention = NSPopUpButton()
    private var pastePending = false
    private var sequenceEnded = false
    private var rendering = false
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private var rows: [ClipboardRow] = []
    var onClose: (() -> Void)?
    var onEvent: ((String, String, String) -> Void)?
    var query: String { search.stringValue }
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("duckpad.plugin.list.sidebar")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: localized("Close"))
        closeButton.bezelStyle = .inline
        closeButton.toolTip = localized("Close")
        closeButton.target = self; closeButton.action = #selector(close)
        closeButton.setAccessibilityIdentifier("duckpad.plugin.list.close")
        let header = NSStackView(views: [heading, closeButton])
        search.delegate = self; search.setAccessibilityIdentifier("duckpad.plugin.list.search")
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.headerView = nil; table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(clickedItem); table.doubleAction = #selector(selectItem)
        table.onActivate = { [weak self] in self?.selectItem() }
        table.setAccessibilityIdentifier("duckpad.plugin.list.items")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        previewHeading.stringValue = localized("Preview")
        previewHeading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        previewHeading.textColor = .secondaryLabelColor
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        preview.textColor = .labelColor; preview.backgroundColor = .textBackgroundColor
        preview.textContainerInset = NSSize(width: 8, height: 8)
        preview.isVerticallyResizable = true; preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        preview.setAccessibilityLabel(localized("Clipboard item preview"))
        imagePreview.setAccessibilityLabel(localized("Clipboard image preview"))
        preview.setAccessibilityIdentifier("duckpad.plugin.list.preview")
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true; previewScroll.borderType = .bezelBorder
        let previewContainer = NSView()
        imagePreview.imageScaling = .scaleProportionallyDown
        imagePreview.setAccessibilityIdentifier("duckpad.plugin.list.image-preview")
        imagePreview.isHidden = true
        for child in [previewScroll, imagePreview] {
            child.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                child.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                child.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            ])
        }
        let previewHeight = previewContainer.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.25)
        previewHeight.priority = .defaultHigh
        let actions = [#selector(selectItem), #selector(selectNext), #selector(pinItem), #selector(deleteItem), #selector(clearItems)]
        let buttons = [pasteButton, nextButton, pinButton, deleteButton, clearButton]
        for (button, action) in zip(buttons, actions) { button.target = self; button.action = action; button.bezelStyle = .rounded }
        // Return belongs to the focused list/search, never to the editor beside it.
        
        retentionLabel.stringValue = localized("Keep history for")
        for (days, title) in [(1, "1 Day"), (3, "3 Days"), (7, "1 Week")] {
            retention.addItem(withTitle: localized(title)); retention.lastItem?.tag = days
        }
        retention.selectItem(withTag: 7)
        retention.target = self; retention.action = #selector(changeRetention)
        retention.toolTip = localized("Expired entries are deleted, including pinned items. History survives restarting Duckpad.")
        retention.setAccessibilityLabel(localized("Keep history for"))
        retention.setAccessibilityIdentifier("duckpad.plugin.list.retention")
        nextButton.setAccessibilityIdentifier("duckpad.plugin.list.paste-next")
        pasteButton.setAccessibilityIdentifier("duckpad.plugin.list.paste")
        let settings = NSStackView(views: [retentionLabel, retention]); settings.spacing = 8
        let stack = NSStackView(views: [header, search, scroll, previewHeading, previewContainer, status, actionBar, settings])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            previewHeight,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            widthAnchor.constraint(lessThanOrEqualToConstant: 600),
        ])
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    func prepareForDisplay() {
        refreshLocalization()
        pastePending = false; sequenceEnded = false; previewID = nil; clearPreview(); updateButtons(); updatePreview()
    }
    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        heading.stringValue = localized(titleKey)
        closeButton.toolTip = localized("Close"); closeButton.setAccessibilityLabel(localized("Close"))
        search.placeholderString = localized("Search clipboard history")
        previewHeading.stringValue = localized("Preview")
        preview.setAccessibilityLabel(localized("Clipboard item preview"))
        imagePreview.setAccessibilityLabel(localized("Clipboard image preview"))
        pasteButton.title = localized("Paste"); nextButton.title = localized("Paste Next")
        nextButton.toolTip = localized("Paste the selected item, then select the next item. Stops at the end of the list.")
        deleteButton.title = localized("Delete"); clearButton.title = localized("Clear History…")
        retentionLabel.stringValue = localized("Keep history for")
        retention.setAccessibilityLabel(localized("Keep history for"))
        retention.toolTip = localized("Expired entries are deleted, including pinned items. History survives restarting Duckpad.")
        for (days, title) in [(1, "1 Day"), (3, "3 Days"), (7, "1 Week")] { retention.itemArray.first { $0.tag == days }?.title = localized(title) }
        status.stringValue = rows.isEmpty ? localized("No clipboard history") : sequenceEnded ? localized("End of history. Select an item to start again.") : ""
        updateButtons()
    }
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.type == .keyDown, modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w",
              let window, event.window === window, window.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor, ownsKeyboardFocus(in: window) else {
            return super.performKeyEquivalent(with: event)
        }
        close()
        return true
    }

    private func ownsKeyboardFocus(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let view = responder as? NSView, view === self || view.isDescendant(of: self) { return true }
        // NSSearchField edits through the window's shared field editor, which
        // may live outside this panel's view hierarchy.
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSView {
            return owner === self || owner.isDescendant(of: self)
        }
        return false
    }

    @objc func close() { previewID = nil; clearPreview(); onClose?() }
    func render(_ rows: [ClipboardRow], retentionDays: Int = 7, error: String?, thumbnails: [String: Data] = [:]) {
        self.thumbnails = thumbnails.compactMapValues { NSImage(data: $0) }
        rendering = true
        defer { rendering = false }
        retention.selectItem(withTag: retentionDays)
        if rows.map(\.id) != self.rows.map(\.id) { sequenceEnded = false }
        if error != nil { pastePending = false }
        let selectedID = selected?.id
        let selectedIndex = table.selectedRow
        let previousRows = self.rows
        let clip = table.enclosingScrollView?.contentView
        let visibleOrigin = clip?.bounds.origin
        let indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        var nextIndex = selectedID.flatMap { indices[$0] }
        if nextIndex == nil, previousRows.indices.contains(selectedIndex) {
            // Keep the user's place when deletion or expiration removes the row.
            // Stable IDs also handle concurrent captures and pinned-row ordering.
            let neighbors = previousRows.dropFirst(selectedIndex + 1) + previousRows.prefix(selectedIndex).reversed()
            nextIndex = neighbors.lazy.compactMap { indices[$0.id] }.first
        }
        self.rows = rows; table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: nextIndex ?? 0), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        if let clip, let visibleOrigin {
            var bounds = clip.bounds; bounds.origin = visibleOrigin
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        if selectedID != nil, selectedID.flatMap({ indices[$0] }) == nil, table.selectedRow >= 0 {
            table.scrollRowToVisible(table.selectedRow)
        }
        status.stringValue = error ?? (rows.isEmpty ? localized("No clipboard history") : sequenceEnded ? localized("End of history. Select an item to start again.") : "")
        updateButtons(); updatePreview()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("clipboard-item")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SingleLineTableCell) ?? SingleLineTableCell()
        cell.identifier = identifier
        let item = rows[row]
        let title = item.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? item.image.map { catalog.text("Image %1$@ × %2$@", arguments: [String($0.width), String($0.height)]) } ?? item.title
        cell.toolTip = item.sourcePath ?? title
        cell.configure(text: (item.pinned ? "📌 " : "") + title, image: item.image.flatMap { thumbnails[$0.digest] })
        return cell
    }
    func controlTextDidChange(_ notification: Notification) { sequenceEnded = false; previewID = nil; clearPreview(); updateButtons(); onEvent?("query", "", query) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { selectItem(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { window?.makeFirstResponder(table); return true }
        return false
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !rendering { sequenceEnded = false; status.stringValue = ""; updatePreview() }
        updateButtons()
    }
    private func updatePreview() {
        guard let item = selected else { previewID = nil; clearPreview(); return }
        guard previewID != item.id else { return }
        previewID = item.id; clearPreview()
        onEvent?("preview", item.id, query)
    }
    func renderPreview(_ text: String, imageData: Data? = nil, id: String, query: String) {
        guard previewID == id, selected?.id == id, self.query == query else { return }
        imagePreview.image = imageData.flatMap { NSImage(data: $0) }
        imagePreview.isHidden = imagePreview.image == nil
        previewScroll.isHidden = !imagePreview.isHidden
        preview.string = text
        preview.scrollToBeginningOfDocument(nil)
    }
    private func clearPreview() {
        preview.string = ""; imagePreview.image = nil
        imagePreview.isHidden = true; previewScroll.isHidden = false
    }
    private var selected: ClipboardRow? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func updateButtons() {
        let image = selected?.image != nil
        pasteButton.title = localized(image ? "Copy Image" : "Paste")
        nextButton.title = localized(image ? "Copy Next" : "Paste Next")
        nextButton.toolTip = localized(image ? "Copy the selected image, then select the next item." : "Paste the selected item, then select the next item. Stops at the end of the list.")
        pasteButton.isEnabled = selected != nil && !pastePending
        nextButton.isEnabled = selected != nil && !pastePending && !sequenceEnded
        pinButton.isEnabled = selected != nil && !pastePending; deleteButton.isEnabled = selected != nil && !pastePending
        retention.isEnabled = !pastePending
        pinButton.title = localized(selected?.pinned == true ? "Unpin" : "Pin")
        clearButton.isEnabled = !rows.isEmpty && !pastePending
        actionBar.refresh()
    }
    @objc private func clickedItem() {
        if selected != nil { sequenceEnded = false; status.stringValue = ""; updateButtons() }
    }
    @objc private func selectItem() { requestPaste(advance: false) }
    @objc private func selectNext() { requestPaste(advance: true) }
    private func requestPaste(advance: Bool) {
        guard !pastePending, !advance || !sequenceEnded, let selected else { return }
        pastePending = true; updateButtons()
        onEvent?(advance ? "select-next" : "select", selected.id, query)
    }
    func finishPaste(id: String, query: String, advance: Bool, succeeded: Bool, copiedImage: Bool = false) {
        pastePending = false
        defer { updateButtons() }
        guard succeeded else {
            status.stringValue = localized("Paste cancelled. Select an editor position and try again."); return
        }
        if copiedImage { status.stringValue = localized("Image copied. Paste it into another app.") }
        guard advance, self.query == query, selected?.id == id else { return }
        let next = table.selectedRow + 1
        if rows.indices.contains(next) {
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
        } else {
            sequenceEnded = true
            status.stringValue = localized("End of history. Select an item to start again.")
        }
    }
    @objc private func changeRetention() {
        onEvent?("retention", String(retention.selectedTag()), query)
    }
    @objc private func pinItem() { if let selected { onEvent?("pin", selected.id, query) } }
    @objc private func deleteItem() { if let selected { onEvent?("delete", selected.id, query) } }
    @objc private func clearItems() {
        let alert = NSAlert(); alert.messageText = localized("Clear all clipboard history, including pinned items?")
        alert.addButton(withTitle: localized("Clear History")); alert.addButton(withTitle: localized("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { onEvent?("clear", "", query) }
    }
}

@MainActor private final class ExtensionListTableView: NSTableView {
    var onActivate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onActivate?()
        } else { super.keyDown(with: event) }
    }
}
