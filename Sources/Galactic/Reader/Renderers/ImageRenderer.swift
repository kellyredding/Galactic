import Foundation

/// Renders an image file as a page.
///
/// The only renderer that reads a path rather than being handed text, because
/// an image is bytes and handing those around as a String would mean encoding
/// them twice.
public enum ImageRenderer {
    /// An image has nothing to point inside of, so an annotation on one is
    /// about the whole document.
    public static let anchoring = ReaderAnchoring.whole

    /// Map a raster image extension to its MIME type for the
    /// inline data URI. SVG is handled separately (inlined as
    /// markup), so it is intentionally absent here.
    static func rasterMIMEType(
        forExtension ext: String
    ) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    public static func document(
        filePath: String,
            isDark: Bool
        ) -> String {
        let theme = ReaderTheme.standard(isDark: isDark)
        let filename = (filePath as NSString)
            .lastPathComponent
        let ext = (filename as NSString)
            .pathExtension.lowercased()

        // For SVG, embed inline if possible
        let isSVG = ext == "svg"
        let svgContent: String?
        if isSVG,
           let data = FileManager.default
               .contents(atPath: filePath),
           let str = String(data: data, encoding: .utf8)
        {
            svgContent = str
        } else {
            svgContent = nil
        }

        let imageElement: String
        if let svg = svgContent {
            // Inline SVG for best rendering
            imageElement = """
            <div class="svg-container">\(svg)</div>
            """
        } else if let data = FileManager.default
            .contents(atPath: filePath)
        {
            // Inline raster bytes as a base64 data URI. A
            // WKWebView loaded via loadHTMLString is not
            // granted file:// subresource read access, so a
            // <img src="file://…"> silently fails to load and
            // renders the broken-image glyph. Embedding the
            // bytes sidesteps the WebKit sandbox entirely.
            let mime = rasterMIMEType(forExtension: ext)
            let base64 = data.base64EncodedString()
            imageElement = """
            <img src="data:\(mime);base64,\(base64)"
                 alt="\(filename)" />
            """
        } else {
            // File unreadable (moved/deleted/permissions).
            imageElement = """
            <div class="image-error">
            Could not read image file:<br>\(filename)
            </div>
            """
        }

        // Checkerboard pattern for transparent images
        let checkerColor = isDark ? "#1a1a2e" : "#f0f0f0"

        return ReaderDocument.render(
            theme: theme,
            title: "Galaxy Artifact Reader",
            css: """
            .image-container {
                display: flex;
                justify-content: center;
                align-items: center;
                min-height: 50vh;
                padding: 24px;
                background-image: linear-gradient(
                    45deg, \(checkerColor) 25%, transparent 25%
                ), linear-gradient(
                    -45deg, \(checkerColor) 25%, transparent 25%
                ), linear-gradient(
                    45deg, transparent 75%, \(checkerColor) 75%
                ), linear-gradient(
                    -45deg, transparent 75%, \(checkerColor) 75%
                );
                background-size: 20px 20px;
                background-position: 0 0, 0 10px,
                    10px -10px, -10px 0px;
            }
            img {
                max-width: 100%;
                max-height: 90vh;
                object-fit: contain;
                border-radius: 4px;
            }
            .svg-container {
                max-width: 100%;
                display: flex;
                justify-content: center;
            }
            .svg-container svg {
                max-width: 100%;
                max-height: 90vh;
            }
            .image-error {
                color: \(theme.foreground);
                font-size: 14px;
                text-align: center;
                line-height: 1.6;
                opacity: 0.7;
            }
            """,
            body: """
            <div class="image-container">
            \(imageElement)
            </div>
            """,
            cardScripts: .withoutAddNote
        )
    }
}
