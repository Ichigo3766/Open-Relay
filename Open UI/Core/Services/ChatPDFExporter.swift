import Foundation
import CoreGraphics
import CoreText

/// A paginated text export of the selected branch, with no media downloads or web execution.
nonisolated enum ChatPDFExporter {
    static func export(title: String, messages: [ChatMessage]) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) { try write(title: title, messages: messages) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func write(title: String, messages: [ChatMessage]) throws -> URL {
        let text = NSMutableAttributedString(string: "")
        var headings: [NSRange] = []
        func append(_ value: String, size: CGFloat = 12, bold: Bool = false) {
            if bold { headings.append(NSRange(location: text.length, length: (value as NSString).length + 2)) }
            text.append(NSAttributedString(string: value + "\n\n", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    (bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)
            ]))
        }
        append(title.isEmpty ? "Chat" : title, size: 22, bold: true)
        append("Text export. Markdown is preserved; attachments and interactive previews are not embedded.", size: 9)
        for message in messages {
            try Task.checkCancellation()
            append(message.role.rawValue.capitalized, size: 14, bold: true)
            if message.role == .assistant {
                for segment in ToolCallParser.parseOrdered(message.content).segments {
                    switch segment {
                    case .text(let content): append(content)
                    case .reasoning(let reasoning):
                        append(reasoning.summary, bold: true)
                        append(reasoning.content)
                    case .toolCall(let tool):
                        append("Tool: " + tool.name, bold: true)
                        if let arguments = tool.arguments { append(arguments) }
                        if let result = tool.result { append(result) }
                    }
                }
            } else {
                append(message.content)
            }
            for file in message.files { append("Attachment: " + (file.name ?? file.type ?? "File"), size: 10) }
        }

        // A fixed prefix and UUID avoid path traversal, title collisions, and overwriting another export.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Chat-\(UUID().uuidString).pdf")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &page, [kCGPDFContextTitle: title] as CFDictionary) else {
            throw Failure.create
        }
        defer { context.closePDF() }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 48, y: 54, width: 516, height: 690), transform: nil)
        var position = 0
        var pageNumber = 1
        while position < text.length {
            try Task.checkCancellation()
            var frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            var visible = CTFrameGetVisibleStringRange(frame)
            // Move an orphan heading to the next page, but allow oversized headings to paginate.
            while let heading = headings.last(where: {
                $0.location > position && $0.location < position + visible.length
                    && NSMaxRange($0) >= position + visible.length
            }) {
                frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: heading.location - position), path, nil)
                visible = CTFrameGetVisibleStringRange(frame)
            }
            guard visible.length > 0 else { throw Failure.layout }
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "\(pageNumber)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 9, nil)
            ])
            context.textPosition = CGPoint(x: 48, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage()
            position += visible.length
            pageNumber += 1
        }
        try Task.checkCancellation()
        completed = true
        return url
    }

    private enum Failure: LocalizedError {
        case create, layout
        var errorDescription: String? {
            self == .create ? "Couldn't create the PDF file." : "Couldn't lay out the chat as a PDF."
        }
    }
}
