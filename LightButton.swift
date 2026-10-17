import AppKit
import CoreText

// Borderless controls use a small drawing surface instead of a full button renderer.
final class LightButton: NSControl {
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var imagePosition: NSControl.ImagePosition = .imageOnly
    var imageHugsTitle = true
    var isBordered = false
    private var textAlignment: NSTextAlignment = .center
    private var textLineBreakMode: NSLineBreakMode = .byTruncatingTail
    override var alignment: NSTextAlignment {
        get { textAlignment }
        set { textAlignment = newValue; needsDisplay = true }
    }
    override var lineBreakMode: NSLineBreakMode {
        get { textLineBreakMode }
        set { textLineBreakMode = newValue; needsDisplay = true }
    }
    var state: NSControl.StateValue = .off { didSet { needsDisplay = true } }
    var contentTintColor: NSColor? { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(title: String = "", target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        font = NSFont.systemFont(ofSize: 13)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    convenience init(image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(target: target, action: action); self.image = image
    }
    convenience init(title: String, image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(title: title, target: target, action: action); self.image = image; imagePosition = .imageLeading
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if pressed || state == .on {
            NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.18 : 0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        if isBordered {
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            border.lineWidth = window?.firstResponder === self ? 2 : 1; border.stroke()
        }
        var textRect = bounds.insetBy(dx: 2, dy: 0)
        if let image {
            let edge = min(CGFloat(24), bounds.height - 2)
            let x = imagePosition == .imageLeading ? 4 : (bounds.width - edge) / 2
            image.draw(in: NSRect(x: x, y: (bounds.height - edge) / 2, width: edge, height: edge),
                       from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
            if imagePosition == .imageLeading { textRect.origin.x = x + edge + 7; textRect.size.width = bounds.maxX - textRect.minX - 3 }
        }
        guard !title.isEmpty else { return }
        LightText.draw(title, in: textRect, font: font ?? NSFont.systemFont(ofSize: 13),
                       color: isEnabled ? (contentTintColor ?? .labelColor) : .disabledControlTextColor,
                       alignment: alignment, truncation: lineBreakMode)
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        _ = sendAction(action, to: target)
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }; performClick(nil); return true
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        pressed = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp {
                pressed = false
                if inside { performClick(nil) }
                return
            }
        }
        pressed = false
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" { performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

final class LightLabel: NSView {
    var stringValue: String { didSet { needsDisplay = true; setAccessibilityValue(stringValue) } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var textColor = NSColor.labelColor { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }
    var maximumNumberOfLines = 1
    var lineBreakMode: NSLineBreakMode = .byClipping

    init(_ text: String) {
        stringValue = text; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityValue(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        LightText.draw(stringValue, in: bounds.insetBy(dx: 2, dy: 0), font: font,
                       color: textColor, alignment: alignment, truncation: lineBreakMode,
                       maximumLines: maximumNumberOfLines, flipped: isFlipped)
    }
}


// Read-only text needs no text editor or TextKit layout manager. CoreText keeps
// drawing, wrapping, Chinese fallback and truncation within the small view.
enum LightText {
    static func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                     alignment: NSTextAlignment = .left, truncation: NSLineBreakMode = .byClipping,
                     maximumLines: Int = 1, flipped: Bool = false) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var lines: [CTLine] = []
        var offset = 0
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let limit = maximumLines == 0 ? max(1, Int(rect.height / lineHeight)) : maximumLines
        while offset < string.length, lines.count < limit {
            let count = limit == 1 ? string.length : max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(rect.width)))
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(rect.width) {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                let kind: CTLineTruncationType = truncation == .byTruncatingMiddle ? .middle : truncation == .byTruncatingHead ? .start : .end
                if truncation != .byClipping, let shortened = CTLineCreateTruncatedLine(line, Double(rect.width), kind, token) { line = shortened }
            }
            lines.append(line); offset += count
        }
        context.saveGState(); context.clip(to: rect); context.textMatrix = .identity
        if flipped { context.translateBy(x: 0, y: rect.minY + rect.maxY); context.scaleBy(x: 1, y: -1) }
        let total = CGFloat(lines.count) * lineHeight
        var baseline = rect.midY + total / 2 - font.ascender
        for line in lines {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = alignment == .right ? rect.maxX - width : alignment == .center ? rect.midX - width / 2 : rect.minX
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context); baseline -= lineHeight
        }
        context.restoreGState()
    }
}

final class LightToggle: NSControl {
    let title: String
    var state: NSControl.StateValue = .off { didSet { needsDisplay = true; setAccessibilityValue(state == .on ? 1 : 0) } }
    init(_ title: String) {
        self.title = title; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.checkBox); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if state == .on {
            NSColor.controlAccentColor.setFill(); path.fill(); NSColor.white.setStroke()
            let tick = NSBezierPath(); tick.move(to: NSPoint(x: box.minX + 3, y: box.midY))
            tick.line(to: NSPoint(x: box.minX + 6.5, y: box.minY + 4)); tick.line(to: NSPoint(x: box.maxX - 3, y: box.maxY - 4))
            tick.lineWidth = 1.8; tick.stroke()
        } else { NSColor.secondaryLabelColor.setStroke(); path.lineWidth = 1; path.stroke() }
        if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); path.lineWidth = 2; path.stroke() }
        LightText.draw(title, in: NSRect(x: 26, y: 0, width: bounds.width - 26, height: bounds.height), font: NSFont.systemFont(ofSize: 13), color: isEnabled ? .labelColor : .disabledControlTextColor)
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }; state = state == .on ? .off : .on; _ = sendAction(action, to: target)
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; performClick(nil); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); performClick(nil) }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { performClick(nil) } else { super.keyDown(with: event) }
    }
}

final class LightPopup: NSControl {
    private var titles: [String] = []
    private(set) var indexOfSelectedItem = 0
    func addItems(withTitles values: [String]) { titles.append(contentsOf: values); selectItem(at: indexOfSelectedItem) }
    func selectItem(at index: Int) {
        guard titles.indices.contains(index) else { return }; indexOfSelectedItem = index
        needsDisplay = true; setAccessibilityValue(titles[index])
    }
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.popUpButton)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        path.lineWidth = window?.firstResponder === self ? 2 : 1; path.stroke()
        guard titles.indices.contains(indexOfSelectedItem) else { return }
        LightText.draw(titles[indexOfSelectedItem], in: NSRect(x: 10, y: 0, width: bounds.width - 33, height: bounds.height), font: NSFont.systemFont(ofSize: 13), color: isEnabled ? .labelColor : .disabledControlTextColor, truncation: .byTruncatingTail)
        let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: bounds.maxX - 18, y: bounds.midY + 2))
        arrow.line(to: NSPoint(x: bounds.maxX - 14, y: bounds.midY - 2)); arrow.line(to: NSPoint(x: bounds.maxX - 10, y: bounds.midY + 2))
        NSColor.secondaryLabelColor.setStroke(); arrow.lineWidth = 1.5; arrow.stroke()
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selected(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == indexOfSelectedItem ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: indexOfSelectedItem), at: NSPoint(x: 0, y: bounds.height), in: self)
    }
    @objc private func selected(_ sender: NSMenuItem) { selectItem(at: sender.tag); _ = sendAction(action, to: target) }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; performClick(nil); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); performClick(nil) }
    override func keyDown(with event: NSEvent) {
        if [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") { performClick(nil) } else { super.keyDown(with: event) }
    }
}

final class LightSegments: NSView {
    weak var target: AnyObject?
    var action: Selector?
    private let buttons: [LightButton]
    var selectedSegment = 0 { didSet { for (i, button) in buttons.enumerated() { button.state = i == selectedSegment ? .on : .off; button.setAccessibilityValue(i == selectedSegment ? 1 : 0) } } }
    init(labels: [String]) {
        buttons = labels.map { LightButton(title: $0) }; super.init(frame: .zero)
        for (index, button) in buttons.enumerated() {
            button.tag = index; button.isBordered = true; button.target = self; button.action = #selector(select(_:)); button.setAccessibilityRole(.radioButton); button.setAccessibilityValue(index == 0 ? 1 : 0); addSubview(button)
        }
        selectedSegment = 0; buttons.first?.state = .on
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); let width = bounds.width / CGFloat(max(buttons.count, 1))
        for (i, button) in buttons.enumerated() { button.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height) }
    }
    @objc private func select(_ button: LightButton) { selectedSegment = button.tag; if let action { NSApp.sendAction(action, to: target, from: self) } }
}
