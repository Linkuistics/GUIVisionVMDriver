import CoreGraphics
import AppKit

public enum WindowCapture {

    // MARK: - Window ID lookup

    /// Finds the CGWindowID for a window identified by app name, position, and size.
    public static func findWindowID(appName: String, position: CGPoint, size: CGSize) -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                  ownerName == appName else { continue }

            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat else { continue }

            if abs(x - position.x) < 2 && abs(y - position.y) < 2 &&
               abs(w - size.width) < 2 && abs(h - size.height) < 2 {
                return windowInfo[kCGWindowNumber as String] as? CGWindowID
            }
        }

        return nil
    }

    // MARK: - Capture methods

    /// Captures the full content of a window as PNG data.
    public static func captureWindow(windowID: CGWindowID) -> Data? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    /// Captures a region of a window as PNG data.
    /// The region is specified relative to the window's top-left corner (screen coordinates).
    public static func captureRegion(windowID: CGWindowID, region: CGRect) -> Data? {
        guard let cgImage = CGWindowListCreateImage(
            region,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    /// Captures the region around an accessibility element with optional padding.
    /// `elementBounds` is the element's bounds in screen coordinates.
    public static func captureElement(windowID: CGWindowID, elementBounds: CGRect, padding: Int = 0) -> Data? {
        let pad = CGFloat(padding)
        let paddedRegion = CGRect(
            x: elementBounds.origin.x - pad,
            y: elementBounds.origin.y - pad,
            width: elementBounds.width + pad * 2,
            height: elementBounds.height + pad * 2
        )
        return captureRegion(windowID: windowID, region: paddedRegion)
    }

    // MARK: - Private helpers

    private static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
