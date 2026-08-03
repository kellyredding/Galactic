import Foundation

/// Renders delimited text as a table, anchored by row.
public enum TableRenderer {
    /// How this renderer's markup is anchored.
    public static let anchoring = ReaderAnchoring.rows()

    public static func document(
        content: String,
        isDark: Bool
    ) -> String {
        let theme = ReaderTheme.standard(isDark: isDark)

        let rows = parseCSV(content)
        guard !rows.isEmpty else {
            return "<html><body>No data</body></html>"
        }

        let headerRow = rows[0]
        let dataRows = Array(rows.dropFirst())

        var headerHTML = "<tr data-row=\"0\""
            + " data-line-start=\"\(headerRow.startLine)\">"
        for cell in headerRow.cells {
            let escaped = HTMLEscape.text(cell)
            headerHTML += "<th>\(escaped)</th>"
        }
        headerHTML += "</tr>"

        var bodyHTML = ""
        for (i, row) in dataRows.enumerated() {
            let rowNum = i + 1
            bodyHTML += "<tr data-row=\"\(rowNum)\""
                + " data-line-start=\"\(row.startLine)\">"
            for cell in row.cells {
                let escaped = HTMLEscape.text(cell)
                bodyHTML += "<td>\(escaped)</td>"
            }
            bodyHTML += "</tr>"
        }

        return ReaderDocument.render(
            theme: theme,
            title: "Galaxy Artifact Reader",
            css: """
            .table-container {
                padding: 16px;
                overflow: auto;
            }
            table {
                border-collapse: collapse;
                width: 100%;
                border: 1px solid \(theme.border);
            }
            th {
                background: \(theme.raisedSurface);
                font-weight: 600;
                text-align: left;
                padding: 8px 12px;
                border: 1px solid \(theme.border);
                white-space: nowrap;
            }
            td {
                padding: 6px 12px;
                border: 1px solid \(theme.border);
                white-space: nowrap;
            }
            tr:nth-child(even) {
                background: \(theme.raisedSurface);
            }
            tr:nth-child(odd) {
                background: \(theme.background);
            }
            /* Annotation highlight for table rows */
            tr.annotation-highlight td {
                background-color: rgba(88, 166, 255, 0.12);
                border-left-color: rgba(88, 166, 255, 0.6);
            }
            tr.annotation-expanded-highlight td {
                background-color:
                    var(--annotation-active-block-bg);
                border-left-color:
                    var(--annotation-active-block-border);
            }
            """,
            body: """
            <div class="table-container">
            <table>
            <thead>\(headerHTML)</thead>
            <tbody>\(bodyHTML)</tbody>
            </table>
            </div>
            """
        )
    }



    /// Simple CSV parser that handles quoted fields.
    /// Rows, each with the 1-based source line it began on.
    ///
    /// Row ordinal and line number agree only until a quoted field
    /// contains a newline, and then silently diverge — which is exactly
    /// when a reference built from the row index would start naming the
    /// wrong place. The ordinal is still what annotations anchor to; the
    /// line travels alongside it purely so a reference can be truthful.
    static func parseCSV(
        _ content: String
    ) -> [(cells: [String], startLine: Int)] {
        var rows: [(cells: [String], startLine: Int)] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        let chars = Array(content)
        var i = 0
        var line = 1
        var rowStartLine = 1

        while i < chars.count {
            let ch = chars[i]

            if inQuotes {
                if ch == "\"" {
                    // Check for escaped quote
                    if i + 1 < chars.count
                        && chars[i + 1] == "\""
                    {
                        currentField.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    if ch == "\n" { line += 1 }
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if ch == "\n" || ch == "\r" {
                    // Handle \r\n
                    if ch == "\r" && i + 1 < chars.count
                        && chars[i + 1] == "\n"
                    {
                        i += 1
                    }
                    line += 1
                    currentRow.append(currentField)
                    currentField = ""
                    if !currentRow.isEmpty {
                        rows.append((
                            cells: currentRow,
                            startLine: rowStartLine
                        ))
                    }
                    currentRow = []
                    rowStartLine = line
                } else {
                    currentField.append(ch)
                }
            }
            i += 1
        }

        // Last field/row
        if !currentField.isEmpty
            || !currentRow.isEmpty
        {
            currentRow.append(currentField)
            rows.append((
                cells: currentRow,
                startLine: rowStartLine
            ))
        }

        return rows
    }
}
