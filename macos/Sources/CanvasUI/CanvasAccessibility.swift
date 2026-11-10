import AppKit
import CanvasCore

public final class CanvasAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    public enum ElementKind: Equatable, Sendable {
        case node(id: String, type: String, shapeKind: String, isLocked: Bool, hasAttachment: Bool)
        case connection(id: String, sourceID: String, targetID: String)
    }

    public let elementID: String
    public let elementKind: ElementKind
    public let titleText: String
    public let roleSummary: String
    public let valueSummary: String
    public let worldBounds: CGRect
    nonisolated(unsafe) private weak var canvasView: CanvasView?

    @MainActor
    public init(
        elementID: String,
        elementKind: ElementKind,
        titleText: String,
        roleSummary: String,
        valueSummary: String,
        worldBounds: CGRect,
        canvasView: CanvasView
    ) {
        self.elementID = elementID
        self.elementKind = elementKind
        self.titleText = titleText
        self.roleSummary = roleSummary
        self.valueSummary = valueSummary
        self.worldBounds = worldBounds
        self.canvasView = canvasView
        super.init()
        setAccessibilityParent(canvasView)
        switch elementKind {
        case .node(let id, _, _, _, _):
            setAccessibilityIdentifier("canvas-node-\(id)")
            setAccessibilityRole(.group)
        case .connection(let id, _, _):
            setAccessibilityIdentifier("canvas-connection-\(id)")
            setAccessibilityRole(.link)
        }
        setAccessibilityRoleDescription(roleSummary)
        setAccessibilityLabel(titleText)
        setAccessibilityValue(valueSummary)
    }

    public override func isAccessibilityElement() -> Bool {
        true
    }

    public override func accessibilityIdentifier() -> String {
        switch elementKind {
        case .node(let id, _, _, _, _):
            return "canvas-node-\(id)"
        case .connection(let id, _, _):
            return "canvas-connection-\(id)"
        }
    }

    public override func accessibilityLabel() -> String? {
        titleText
    }

    public override func accessibilityRoleDescription() -> String? {
        roleSummary
    }

    public override func accessibilityValue() -> Any? {
        valueSummary
    }

    public override func isAccessibilitySelected() -> Bool {
        let view = canvasView
        let kind = elementKind
        return MainActor.assumeIsolated {
            guard let view else { return false }
            switch kind {
            case .node(let id, _, _, _, _):
                return view.selectedNodeIDs.contains(id) || view.selectedNodeID == id
            case .connection(let id, _, _):
                return view.selectedConnectionID == id
            }
        }
    }

    public override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        let view = canvasView
        let kind = elementKind
        let currentlySelected = isAccessibilitySelected()
        MainActor.assumeIsolated {
            guard let view else { return }
            if accessibilitySelected {
                switch kind {
                case .node(let id, _, _, _, _):
                    view.selectNode(id)
                case .connection(let id, _, _):
                    view.selectConnection(id)
                }
            } else if currentlySelected {
                view.deselectAll()
            }
        }
    }

    public override func accessibilityFrame() -> NSRect {
        let view = canvasView
        let bounds = worldBounds
        return MainActor.assumeIsolated {
            guard let view else { return bounds }
            let viewRect = view.viewRect(forWorldRect: bounds)
            guard let window = view.window else { return viewRect }
            let windowRect = view.convert(viewRect, to: nil)
            return window.convertToScreen(windowRect)
        }
    }

    public override func accessibilityPerformPress() -> Bool {
        let view = canvasView
        let kind = elementKind
        return MainActor.assumeIsolated {
            guard let view else { return false }
            view.window?.makeFirstResponder(view)
            switch kind {
            case .node(let id, _, _, _, _):
                view.selectNode(id)
                return true
            case .connection(let id, _, _):
                view.selectConnection(id)
                return true
            }
        }
    }
}
