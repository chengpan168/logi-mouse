import AppKit

final class ScrollTestDocumentView: NSView {
    static let documentHeight: CGFloat = 1_000_000
    private static let rowHeight: CGFloat = 32

    override var isFlipped: Bool { true }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.documentHeight))
        autoresizingMask = [.width]
        setAccessibilityLabel("Long controlled scrolling surface")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let firstRow = max(0, Int(floor(dirtyRect.minY / Self.rowHeight)))
        let lastRow = min(
            Int(Self.documentHeight / Self.rowHeight),
            Int(ceil(dirtyRect.maxY / Self.rowHeight))
        )
        let regularAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let markerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        for row in firstRow...lastRow {
            let y = CGFloat(row) * Self.rowHeight
            let isMarker = row.isMultiple(of: 10)
            if isMarker {
                NSColor.separatorColor.setStroke()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 18, y: y))
                path.line(to: NSPoint(x: bounds.width - 18, y: y))
                path.stroke()
            }
            let position = Int(y)
            let text = String(format: "%07d px%@", position, isMarker ? "  ← reference marker" : "")
            text.draw(
                at: NSPoint(x: 22, y: y + 8),
                withAttributes: isMarker ? markerAttributes : regularAttributes
            )
        }
    }
}
