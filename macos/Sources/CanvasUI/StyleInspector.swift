import AppKit
import CanvasCore

@MainActor
public final class StyleInspectorView: NSView {
    private final class InspectorButton: NSButton {
        var onEscape: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onEscape?()
                return
            }
            if event.modifierFlags.contains(.command) {
                superview?.keyDown(with: event)
                return
            }
            super.keyDown(with: event)
        }
    }

    private final class InspectorPopUpButton: NSPopUpButton {
        var onEscape: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onEscape?()
                return
            }
            if event.modifierFlags.contains(.command) {
                superview?.keyDown(with: event)
                return
            }
            super.keyDown(with: event)
        }
    }

    private struct Option {
        let label: String
        let value: CanvasStyleValue
    }

    private let titleLabel: NSTextField
    private let closeButton: InspectorButton
    private let messageLabel: NSTextField
    private let errorLabel: NSTextField
    private var currentTargetKey: String = ""
    private var currentSchema: [CanvasStyleProperty] = []
    private var currentIsConnection: Bool = false
    private var currentIsDocument: Bool = false
    private var rowViews: [NSView] = []
    private var controlsByProperty: [CanvasStyleProperty: InspectorPopUpButton] = [:]
    private var optionsByProperty: [CanvasStyleProperty: [Option]] = [:]
    var onSelectStyle: ((CanvasStyleProperty, CanvasStyleValue) throws -> Void)?
    var onClose: (() -> Void)?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init() {
        titleLabel = NSTextField(labelWithString: "Style")
        closeButton = InspectorButton(title: "Close", target: nil, action: nil)
        messageLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel = NSTextField(wrappingLabelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 268, height: 120))
        identifier = NSUserInterfaceItemIdentifier("style-inspector")
        setAccessibilityLabel("Style inspector")

        titleLabel.identifier = NSUserInterfaceItemIdentifier("style-title")
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = CanvasTheme.primaryText

        closeButton.identifier = NSUserInterfaceItemIdentifier("style-close")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.bezelStyle = .rounded
        closeButton.font = .systemFont(ofSize: 12, weight: .medium)
        closeButton.setAccessibilityLabel("Close Style inspector")
        closeButton.onEscape = { [weak self] in self?.onClose?() }

        messageLabel.identifier = NSUserInterfaceItemIdentifier("style-message")
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = CanvasTheme.secondaryText
        messageLabel.isHidden = true

        errorLabel.identifier = NSUserInterfaceItemIdentifier("style-error")
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(messageLabel)
        addSubview(errorLabel)
    }

    public required init?(coder: NSCoder) {
        fatalError("StyleInspectorView does not support NSCoder")
    }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.elevatedSurface.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        border.stroke()
        let headerDivider = NSBezierPath()
        headerDivider.move(to: CGPoint(x: 0, y: 40))
        headerDivider.line(to: CGPoint(x: bounds.width, y: 40))
        headerDivider.lineWidth = 1
        CanvasTheme.borderSubtle.setStroke()
        headerDivider.stroke()
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseDragged(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
            return
        }
        if event.modifierFlags.contains(.command) {
            superview?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    public func focusPrimaryControl() {
        for property in currentSchema {
            if let control = controlsByProperty[property], control.isEnabled {
                window?.makeFirstResponder(control)
                return
            }
        }
        window?.makeFirstResponder(closeButton)
    }

    public func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
        layoutContents()
        needsDisplay = true
    }

    public func clearError() {
        guard !errorLabel.isHidden else { return }
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        layoutContents()
        needsDisplay = true
    }

    func update(
        session: CanvasSession,
        selectedNodeID: String?,
        selectedConnectionID: String?,
        hasGeometryPreview: Bool
    ) {
        let targetKey = "\(selectedNodeID ?? "")|\(selectedConnectionID ?? "")"
        let targetChanged = targetKey != currentTargetKey
        currentTargetKey = targetKey
        if targetChanged {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }

        let isConnection = selectedNodeID == nil && selectedConnectionID != nil
        let isDocument = selectedNodeID == nil && selectedConnectionID == nil
        let schema: [CanvasStyleProperty]
        let effective: [CanvasStyleProperty: CanvasStyleValue]
        let title: String
        var blocked = ""

        if let nodeID = selectedNodeID,
           let raw = (session.root["nodes"] as? [[String: Any]])?.first(where: { $0["id"] as? String == nodeID }) {
            let type = raw["type"] as? String ?? "shape"
            let data = raw["data"] as? [String: Any] ?? [:]
            if type == "shape" {
                switch data["kind"] as? String ?? "rect" {
                case "ellipse": title = "Ellipse"
                case "diamond": title = "Diamond"
                case "triangle": title = "Triangle"
                case "text": title = "Text"
                default: title = "Rectangle"
                }
            } else if type == "shape-line" {
                title = "Line"
            } else if type == "code" {
                title = "Code block"
            } else {
                title = "Object"
            }
            schema = session.availableStyleProperties(forNode: nodeID)
            effective = session.effectiveNodeStyle(of: nodeID) ?? [:]
            if hasGeometryPreview {
                blocked = "Finish the active geometry preview to change styles."
            } else if session.isLocked(nodeID) {
                blocked = "Unlock the selected object before changing styles."
            }
        } else if let edgeID = selectedConnectionID, session.hasConnection(edgeID) {
            title = "Connection"
            schema = session.availableStyleProperties(forConnection: edgeID)
            effective = session.effectiveConnectionStyle(of: edgeID) ?? [:]
            if hasGeometryPreview {
                blocked = "Finish the active geometry preview to change styles."
            }
        } else {
            title = "Canvas"
            schema = session.availableDocumentStyleProperties()
            effective = session.effectiveDocumentStyle()
            if hasGeometryPreview {
                blocked = "Finish the active geometry preview to change styles."
            }
        }

        titleLabel.stringValue = title
        messageLabel.stringValue = blocked
        messageLabel.isHidden = blocked.isEmpty

        if schema != currentSchema || isConnection != currentIsConnection || isDocument != currentIsDocument {
            rebuildControls(schema: schema, isConnection: isConnection, isDocument: isDocument)
        }
        syncControlValues(effective: effective, enabled: blocked.isEmpty, isConnection: isConnection)
        layoutContents()
        needsDisplay = true
    }

    private func rebuildControls(schema: [CanvasStyleProperty], isConnection: Bool, isDocument: Bool) {
        for view in rowViews { view.removeFromSuperview() }
        rowViews.removeAll()
        controlsByProperty.removeAll()
        optionsByProperty.removeAll()
        currentSchema = schema
        currentIsConnection = isConnection
        currentIsDocument = isDocument

        var addedAppearanceHeader = false
        var addedTextHeader = false
        for property in schema {
            let isTextCategory = [.font, .size, .align].contains(property)
            if !isTextCategory && !addedAppearanceHeader {
                addedAppearanceHeader = true
                let sectionLabel = NSTextField(labelWithString: "APPEARANCE")
                sectionLabel.font = .systemFont(ofSize: 10, weight: .bold)
                sectionLabel.textColor = CanvasTheme.mutedText
                addSubview(sectionLabel)
                rowViews.append(sectionLabel)
            } else if isTextCategory && !addedTextHeader {
                addedTextHeader = true
                let sectionLabel = NSTextField(labelWithString: "TEXT")
                sectionLabel.font = .systemFont(ofSize: 10, weight: .bold)
                sectionLabel.textColor = CanvasTheme.mutedText
                addSubview(sectionLabel)
                rowViews.append(sectionLabel)
            }

            let propLabel = Self.label(for: property, isDocument: isDocument)
            let label = NSTextField(labelWithString: propLabel)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = CanvasTheme.primaryText
            addSubview(label)
            rowViews.append(label)

            let popup = InspectorPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = NSUserInterfaceItemIdentifier("style-\(property.rawValue)")
            popup.target = self
            popup.action = #selector(controlChanged(_:))
            popup.font = .systemFont(ofSize: 12)
            popup.setAccessibilityLabel(propLabel)
            popup.onEscape = { [weak self] in self?.onClose?() }
            addSubview(popup)
            rowViews.append(popup)
            controlsByProperty[property] = popup
        }
    }

    private func syncControlValues(
        effective: [CanvasStyleProperty: CanvasStyleValue],
        enabled: Bool,
        isConnection: Bool
    ) {
        for property in currentSchema {
            guard let popup = controlsByProperty[property] else { continue }
            let value = effective[property]
            let options = Self.options(
                for: property,
                isConnection: isConnection,
                includeOmittedStroke: value == .omitted,
                currentValue: value
            )
            let existingTitles = popup.itemTitles
            let desiredTitles = options.map(\.label)
            if existingTitles != desiredTitles {
                popup.removeAllItems()
                popup.addItems(withTitles: desiredTitles)
            }
            optionsByProperty[property] = options
            if let value, let index = options.firstIndex(where: { $0.value == value }) {
                popup.selectItem(at: index)
            }
            popup.isEnabled = enabled
        }
    }


    private func layoutContents() {
        let width: CGFloat = 268
        let padding: CGFloat = 12
        titleLabel.frame = NSRect(x: padding, y: 11, width: 170, height: 18)
        closeButton.frame = NSRect(x: width - padding - 60, y: 7, width: 60, height: 26)

        var y: CGFloat = 48
        if !messageLabel.isHidden {
            let size = messageLabel.sizeThatFits(NSSize(width: width - padding * 2, height: 200))
            messageLabel.frame = NSRect(x: padding, y: y, width: width - padding * 2, height: ceil(size.height))
            y += ceil(size.height) + 8
        }
        var index = 0
        while index < rowViews.count {
            let view = rowViews[index]
            if let field = view as? NSTextField,
               field.stringValue == "APPEARANCE" || field.stringValue == "TEXT" {
                field.frame = NSRect(x: padding, y: y + 2, width: width - padding * 2, height: 14)
                y += 20
                index += 1
            } else if index + 1 < rowViews.count {
                let label = rowViews[index]
                let control = rowViews[index + 1]
                label.frame = NSRect(x: padding, y: y + 4, width: 108, height: 18)
                control.frame = NSRect(x: padding + 112, y: y, width: width - padding * 2 - 112, height: 26)
                y += 32
                index += 2
            } else {
                index += 1
            }
        }
        if !errorLabel.isHidden {
            let size = errorLabel.sizeThatFits(NSSize(width: width - padding * 2, height: 200))
            errorLabel.frame = NSRect(x: padding, y: y + 2, width: width - padding * 2, height: ceil(size.height))
            y += ceil(size.height) + 8
        }
        setFrameSize(NSSize(width: width, height: max(84, y + 8)))
    }

    @objc private func controlChanged(_ sender: NSPopUpButton) {
        guard let rawID = sender.identifier?.rawValue,
              rawID.hasPrefix("style-"),
              let property = CanvasStyleProperty(rawValue: String(rawID.dropFirst("style-".count))),
              let options = optionsByProperty[property] else { return }
        let selectedIndex = sender.indexOfSelectedItem
        guard (0..<options.count).contains(selectedIndex) else { return }
        let choice = options[selectedIndex].value
        guard choice != .omitted else { return }
        do {
            clearError()
            try onSelectStyle?(property, choice)
        } catch {
            showError(error.localizedDescription)
            NSSound.beep()
        }
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    private static func label(for property: CanvasStyleProperty, isDocument: Bool = false) -> String {
        switch property {
        case .paperBackground: return "Paper"
        case .paperGrid: return "Grid size"
        case .fill: return "Fill"
        case .stroke: return "Stroke"
        case .width: return "Stroke width"
        case .dash: return "Stroke style"
        case .radius: return "Corners"
        case .arrow: return "Arrowheads"
        case .path: return "Path"
        case .marker: return "Target marker"
        case .font: return isDocument ? "Default text" : "Text style"
        case .size: return "Text size"
        case .align: return isDocument ? "Default alignment" : "Alignment"
        }
    }
    private static func options(
        for property: CanvasStyleProperty,
        isConnection: Bool,
        includeOmittedStroke: Bool,
        currentValue: CanvasStyleValue? = nil
    ) -> [Option] {
        switch property {
        case .paperBackground:
            return [
                Option(label: "Dots", value: .string("dots")),
                Option(label: "Lines", value: .string("lines")),
                Option(label: "Cross", value: .string("cross")),
                Option(label: "None", value: .string("none"))
            ]
        case .paperGrid:
            var grids = CanvasSession.defaultPaperGridPresets
            if case .int(let current) = currentValue, !grids.contains(current) {
                grids.append(current)
                grids.sort()
            }
            return grids.map { Option(label: "\($0) px", value: .int($0)) }
        case .fill, .stroke:
            var list: [Option] = []
            if property == .stroke && isConnection && includeOmittedStroke {
                list.append(Option(label: "Default", value: .omitted))
            }
            for color in CanvasSession.supportedColors {
                list.append(Option(label: color.capitalized, value: .string(color)))
            }
            return list
        case .width:
            return [
                Option(label: "Thin", value: .int(1)),
                Option(label: "Medium", value: .int(2)),
                Option(label: "Thick", value: .int(4))
            ]
        case .dash:
            return [
                Option(label: "Solid", value: .bool(false)),
                Option(label: "Dashed", value: .bool(true))
            ]
        case .radius:
            return [
                Option(label: "Sharp", value: .int(0)),
                Option(label: "Rounded", value: .int(8))
            ]
        case .arrow:
            return [
                Option(label: "End", value: .string("end")),
                Option(label: "Both", value: .string("both")),
                Option(label: "None", value: .string("none"))
            ]
        case .path:
            return [
                Option(label: "Curved", value: .string("bezier")),
                Option(label: "Smooth", value: .string("smooth")),
                Option(label: "Step", value: .string("step")),
                Option(label: "Straight", value: .string("straight"))
            ]
        case .marker:
            return [
                Option(label: "Arrow", value: .string("arrow")),
                Option(label: "Dot", value: .string("dot")),
                Option(label: "None", value: .string("none"))
            ]
        case .font:
            return [
                Option(label: "Normal", value: .string("sans")),
                Option(label: "Title", value: .string("heading")),
                Option(label: "Mono", value: .string("mono")),
                Option(label: "Handwritten", value: .string("handwritten"))
            ]
        case .size:
            return [
                Option(label: "Small", value: .string("s")),
                Option(label: "Medium", value: .string("m")),
                Option(label: "Large", value: .string("l"))
            ]
        case .align:
            return [
                Option(label: "Left", value: .string("left")),
                Option(label: "Center", value: .string("center")),
                Option(label: "Right", value: .string("right"))
            ]
        }
    }
}
