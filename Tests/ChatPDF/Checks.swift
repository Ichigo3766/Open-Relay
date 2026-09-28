import Foundation
import PDFKit

@main struct Checks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        precondition(value(), name); count += 1
    }
    static func main() async throws {
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("Chat-") }
        let empty = try await ChatPDFExporter.export(title: "", messages: [])
        defer { try? FileManager.default.removeItem(at: empty) }
        let emptyPDF = PDFDocument(url: empty)!
        check(emptyPDF.pageCount == 1, "Empty chat has a valid single page")
        check(emptyPDF.string!.contains("Chat"), "Empty title fallback")
        let content = (1...120).map { "Line \($0): Fold a paper star with five points. Repeat each crease carefully." }.joined(separator: "\n")
        let messages = [
            ChatMessage(role: .user, content: "Make a paper star. Café, Ελληνικά, 日本語."),
            ChatMessage(role: .assistant, content: "<think>Use equal folds.</think>\n" + content
                        + "\n<details type=\"tool_calls\" name=\"count_points\" done=\"true\" arguments=\"{&quot;points&quot;:5}\" result=\"Five points confirmed.\"><summary>Tool</summary></details>\nFINAL-MARKER", files: [ChatMessageFile(type: "file", url: "https://example.test/never-download", name: "diagram.pdf", contentType: "application/pdf")])
        ]
        let url = try await ChatPDFExporter.export(title: "../../Paper craft", messages: messages)
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = PDFDocument(url: url)!
        let text = pdf.string!
        check(pdf.pageCount > 2, "Long transcript is paginated")
        check(text.contains("../../Paper craft"), "Title is preserved as content")
        check(url.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL, "Title cannot escape temp directory")
        check(text.contains("FINAL-MARKER"), "End of long content is present")
        for number in 1...120 { check(text.contains("Line \(number):"), "Every line survives pagination") }
        check(text.components(separatedBy: "FINAL-MARKER").count == 2, "No duplicate content")
        check(text.contains("Café") && text.contains("日本語"), "Unicode fallback is preserved")
        check(text.contains("Use equal folds."), "Thinking content is preserved")
        check(text.contains("Tool: count_points") && text.contains("Five points confirmed."), "Tool text is readable")
        check(!text.contains("<details") && !text.contains("&quot;"), "Internal tool markup is removed")
        check(text.contains("Attachment: diagram.pdf"), "Attachment label without a download")
        check(!text.contains("never-download"), "No attachment URL or media bytes embedded")
        check(url != empty, "Independent exports cannot overwrite each other")
        for index in 0..<pdf.pageCount {
            check(pdf.page(at: index)!.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 612, height: 792), "Consistent page size")
            check(pdf.page(at: index)!.string!.hasSuffix("\(index + 1)"), "Page footer")
            let lines = pdf.page(at: index)!.string!.components(separatedBy: .newlines).filter { !$0.isEmpty && Int($0) == nil }
            check(lines.last != "Tool: count_points", "Keep a tool heading with its content")
        }
        if let output = ProcessInfo.processInfo.environment["PDF_REVIEW_OUTPUT"] {
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: output))
        }
        let cancelled = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChatPDFExporter.export(title: "Cancelled", messages: messages)
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must throw") }
        catch is CancellationError { count += 1 }
        let longWord = try await ChatPDFExporter.export(title: "Long token", messages: [ChatMessage(role: .user, content: String(repeating: "x", count: 15000) + "END-TOKEN")])
        defer { try? FileManager.default.removeItem(at: longWord) }
        check(PDFDocument(url: longWord)!.string!.contains("END-TOKEN"), "Unbroken tokens cannot truncate export")
        let filesAfter = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("Chat-") }
        check(filesAfter.count == filesBefore.count + 3, "Cancellation leaves no partial export")
        print("\(count) PDF checks passed (\(pdf.pageCount) review pages)")
    }
}
