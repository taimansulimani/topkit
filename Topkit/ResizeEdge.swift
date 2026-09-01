import AppKit

enum ResizeEdge: Equatable {
    case none
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    
    var cursor: NSCursor {
        switch self {
        case .none:
            return .arrow
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            // Diagonal NW-SE resize cursor
            return NSCursor(image: NSCursor.crosshair.image, hotSpot: NSPoint(x: 8, y: 8))
        case .topRight, .bottomLeft:
            // Diagonal NE-SW resize cursor
            return NSCursor(image: NSCursor.crosshair.image, hotSpot: NSPoint(x: 8, y: 8))
        }
    }
    
    // Custom diagonal cursors - use system resize cursors rotated appropriately
    static var resizeNWSE: NSCursor {
        // Create diagonal resize cursor (top-left to bottom-right)
        if let image = createDiagonalResizeCursorImage(angle: -45) {
            return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
        }
        return .crosshair
    }
    
    static var resizeNESW: NSCursor {
        // Create diagonal resize cursor (top-right to bottom-left)
        if let image = createDiagonalResizeCursorImage(angle: 45) {
            return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
        }
        return .crosshair
    }
    
    private static func createDiagonalResizeCursorImage(angle: CGFloat) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        
        // Draw a diagonal double-arrow
        let path = NSBezierPath()
        let center = NSPoint(x: 8, y: 8)
        let length: CGFloat = 6
        let arrowSize: CGFloat = 3
        
        let radians = angle * .pi / 180
        let dx = cos(radians) * length
        let dy = sin(radians) * length
        
        // Line
        NSColor.black.setStroke()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: center.x - dx, y: center.y - dy))
        path.line(to: NSPoint(x: center.x + dx, y: center.y + dy))
        
        // Arrow heads
        let perpAngle = radians + .pi / 2
        let perpDx = cos(perpAngle) * arrowSize * 0.5
        let perpDy = sin(perpAngle) * arrowSize * 0.5
        
        // First arrow head
        path.move(to: NSPoint(x: center.x - dx, y: center.y - dy))
        path.line(to: NSPoint(x: center.x - dx + cos(radians) * arrowSize + perpDx,
                              y: center.y - dy + sin(radians) * arrowSize + perpDy))
        path.move(to: NSPoint(x: center.x - dx, y: center.y - dy))
        path.line(to: NSPoint(x: center.x - dx + cos(radians) * arrowSize - perpDx,
                              y: center.y - dy + sin(radians) * arrowSize - perpDy))
        
        // Second arrow head
        path.move(to: NSPoint(x: center.x + dx, y: center.y + dy))
        path.line(to: NSPoint(x: center.x + dx - cos(radians) * arrowSize + perpDx,
                              y: center.y + dy - sin(radians) * arrowSize + perpDy))
        path.move(to: NSPoint(x: center.x + dx, y: center.y + dy))
        path.line(to: NSPoint(x: center.x + dx - cos(radians) * arrowSize - perpDx,
                              y: center.y + dy - sin(radians) * arrowSize - perpDy))
        
        path.stroke()
        image.unlockFocus()
        return image
    }
}
