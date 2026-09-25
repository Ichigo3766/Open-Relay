import Darwin
import Litext
import MarkdownParser
import MarkdownView
import SwiftUI
import XCTest
@testable import Open_UI

@MainActor private final class RenderState: ObservableObject {
    @Published var text = ""
    @Published var streaming = true
    var assistant = false
}
private struct Fixture: View {
    @ObservedObject var state: RenderState
    var body: some View {
        ScrollView {
            if state.assistant {
                AssistantMessageContent(content: state.text, isStreaming: state.streaming)
            } else {
                StreamingMarkdownView(content: state.text, isStreaming: state.streaming)
            }
        }.padding(.horizontal, 20)
    }
}
@MainActor private final class FrameProbe: NSObject {
    var times: [Double] = []
    var link: CADisplayLink?
    var observe: (() -> Void)?
    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    @objc func tick() { times.append(CACurrentMediaTime()); observe?() }
    func stop() { link?.invalidate(); link = nil }
}

@MainActor final class NativeTests: XCTestCase {
    let sentence = "The invented observatory has a copper telescope and seven paper stars. "
    func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    func rendered(_ window: UIWindow) -> String {
        views(window).compactMap { ($0 as? MarkdownTextView)?.textView.attributedText.string }.joined()
    }
    func blocks(_ root: UIView) -> [MarkdownBlockNode] {
        if let view = root as? MarkdownTextView {
            guard let cache = Mirror(reflecting: view).children.first(where: { $0.label == "cachedBlockSegments" })?.value else { return [MarkdownBlockNode]() }
            return Mirror(reflecting: cache).children.compactMap { segment in
                Mirror(reflecting: segment.value).children.first { $0.label == "node" }?.value as? MarkdownBlockNode
            }
        }
        if let code = root as? CodeView {
            let fields = Mirror(reflecting: code).children
            guard let language = fields.first(where: { $0.label == "language" })?.value as? String,
                  var content = fields.first(where: { $0.label == "content" })?.value as? String else { return [] }
            // The original direct code view omits the parser's terminal newline.
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            return [.codeBlock(fenceInfo: language.isEmpty ? nil : language, content: content)]
        }
        return root.subviews.flatMap(blocks)
    }
    private func host(_ state: RenderState) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Fixture(state: state))
        window.makeKeyAndVisible()
        return window
    }
    func settle(_ window: UIWindow, milliseconds: Int = 250) async throws {
        for _ in 0..<max(1, milliseconds / 10) {
            window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(10))
        }
    }
    func testPipelineDelivery() async throws {
        for (name, size, interval, count) in [("slow",20,500,8),("medium",20,100,20),("fast",200,100,20)] {
            for trial in 0..<3 {
                var output = "", first: Double?, idle = false
                let pipeline = StreamingPipeline { value in
                    if value.isActive {
                        output = value.displayContent
                        if first == nil && !output.isEmpty { first = CACurrentMediaTime() }
                    } else { idle = true }
                }
                await pipeline.beginWithPrefix("")
                let start = CACurrentMediaTime(), cpuStart = cpu()
                var input = ""
                for _ in 0..<count {
                    input += String(repeating: "x", count: size)
                    await pipeline.append(input)
                    try await Task.sleep(for: .milliseconds(interval))
                }
                let pending = input.count - output.count, done = CACurrentMediaTime()
                await pipeline.setFinalContent(input)
                for _ in 0..<2000 where !idle { try await Task.sleep(for: .milliseconds(2)) }
                print("IOS_BENCH pipeline=\(name) trial=\(trial) first_ms=\(((first ?? start)-start)*1000) finish_ms=\((CACurrentMediaTime()-done)*1000) pending=\(pending) cpu_ms=\((cpu()-cpuStart)*1000)")
                XCTAssertTrue(idle); XCTAssertEqual(output, input)
                #if !QA_BASELINE
                XCTAssertEqual(pending, 0)
                #endif
            }
        }
    }
    func testNativeFirstText() async throws {
        for trial in 0..<5 {
            let state = RenderState(), window = try host(RenderState())
            window.rootViewController = UIHostingController(rootView: Fixture(state: state))
            try await settle(window)
            var first: Double?
            let probe = FrameProbe()
            probe.observe = { if first == nil && self.rendered(window).contains("Observatory") { first = CACurrentMediaTime() } }
            probe.start()
            let pipeline = StreamingPipeline { value in if value.isActive { state.text = value.displayContent } }
            await pipeline.beginWithPrefix("")
            let start = CACurrentMediaTime()
            var text = "Observatory marker. "
            for _ in 0..<5 {
                await pipeline.append(text)
                try await Task.sleep(for: .milliseconds(500))
                text += "Twenty more letters. "
            }
            await pipeline.setFinalContent(text)
            try await settle(window)
            probe.stop()
            XCTAssertNotNil(first)
            print("IOS_BENCH native_first trial=\(trial) ready_at_display_callback_ms=\(((first ?? start)-start)*1000)")
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testTypewriterProgress() async throws {
        #if !QA_BASELINE
        let state = RenderState(), window = try host(state)
        try await settle(window)
        var samples: [String] = []
        let probe = FrameProbe()
        // The native paragraph builder adds one layout newline, not present in
        // the source. Keep the assertion about the actual visible characters.
        probe.observe = {
            let text = self.rendered(window)
            samples.append(text.hasSuffix("\n") ? String(text.dropLast()) : text)
        }
        probe.start()
        state.text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        try await settle(window, milliseconds: 60)
        state.streaming = false
        try await settle(window, milliseconds: 500)
        probe.stop()
        let lengths = Set(samples.map(\.count))
        print("TYPEWRITER visible_lengths=\(lengths.sorted())")
        XCTAssertGreaterThan(lengths.filter { $0 > 0 && $0 < 26 }.count, 5,
                             "Actual native text must pass through character prefixes, not a whole-chunk jump")
        XCTAssertTrue(samples.allSatisfy { state.text.hasPrefix($0) })
        XCTAssertEqual(rendered(window), state.text + "\n")
        window.isHidden = true; window.rootViewController = nil
        #endif
    }
    func testTypewriterFullPipelineCost() async throws {
        let prose = (1...1250).map { "Section \($0). " + sentence + "\n\n" }.joined()
        let code = "~~~swift\n" + (1...120).map { "let observation\($0) = \($0) // synthetic" }.joined(separator: "\n") + "\n~~~"
        let reasoning = "<details type=\"reasoning\" done=\"true\"><summary>Thinking</summary>" + String(repeating: sentence, count: 1500) + "</details>\n\n"
        let cases = [
            ("slow", "", String(repeating: sentence, count: 4), 20, 150),
            ("large", "", prose, 700, 30),
            ("code", "", code, 40, 30),
            ("reasoning", reasoning, String(repeating: sentence, count: 8), 20, 30),
        ]
        for (name, prefix, text, step, interval) in cases {
            let state = RenderState()
            let window = try host(state)
            try await settle(window)
            var idle = false
            let prefixBytes = prefix.utf8.count
            let pipeline = StreamingPipeline { snapshot in
                if snapshot.isActive {
                    // As in the chat's frozen-prefix render path, the settled
                    // reasoning is not reparsed as part of each answer update.
                    // Strip this fixture's known prefix without another O(N)
                    // character scan, in both original and candidate builds.
                    let bytes = snapshot.displayContent.utf8
                    if prefixBytes == 0 {
                        state.text = snapshot.displayContent
                    } else if bytes.count >= prefixBytes {
                        state.text = String(decoding: bytes.dropFirst(prefixBytes), as: UTF8.self)
                    }
                }
                else { state.streaming = false; idle = true }
            }
            await pipeline.beginWithPrefix(prefix)
            try await settle(window)
            let probe = FrameProbe(); probe.start()
            let started = CACurrentMediaTime(), cpuStart = cpu()
            let initialMemory = footprint()
            var sampledMemory = initialMemory
            let values = stride(from: step, to: text.count, by: step).map { prefix + String(text.prefix($0)) } + [prefix + text]
            for (index, value) in values.enumerated() {
                let deadline = started + Double(index * interval) / 1000
                let wait = deadline - CACurrentMediaTime()
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                await pipeline.append(value)
                sampledMemory = max(sampledMemory, footprint())
            }
            await pipeline.setFinalContent(prefix + text)
            let finishDeadline = CACurrentMediaTime() + 90
            while !idle && CACurrentMediaTime() < finishDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(idle)
            try await settle(window, milliseconds: 800)
            let elapsed = (CACurrentMediaTime() - started) * 1000
            let cost = (cpu() - cpuStart) * 1000
            probe.stop()
            let gaps = zip(probe.times, probe.times.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            sampledMemory = max(sampledMemory, footprint())
            print("TYPEWRITER_BENCH case=\(name) cpu_ms=\(cost) elapsed_ms=\(elapsed) gap_p95_ms=\(gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count - 1) * 0.95)]) gaps_over50=\(gaps.filter { $0 > 50 }.count) footprint_start_mib=\(Double(initialMemory) / 1048576) footprint_sampled_max_mib=\(Double(sampledMemory) / 1048576)")
            if prefix.isEmpty {
                let expected = MarkdownView.PreprocessedContent(parserResultNoMath: MarkdownParser().parse(text)).split().flatMap(\.blocks)
                XCTAssertEqual(blocks(window), expected)
            } else { XCTAssertTrue(rendered(window).contains("seven paper stars")) }
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testWarmShortTypewriterCost() async throws {
        // Isolate steady animation from app startup and first-use initialization.
        try await Task.sleep(for: .seconds(3))
        for trial in 0..<6 {
            let state = RenderState(), window = try host(state)
            try await settle(window)
            let text = "Trial \(trial). " + String(repeating: sentence, count: 4)
            var idle = false
            let pipeline = StreamingPipeline { snapshot in
                if snapshot.isActive { state.text = snapshot.displayContent }
                else { state.streaming = false; idle = true }
            }
            await pipeline.beginWithPrefix("")
            let values = stride(from: 20, to: text.count, by: 20).map { String(text.prefix($0)) } + [text]
            let started = CACurrentMediaTime(), cpuStart = cpu()
            for (index, value) in values.enumerated() {
                let wait = started + Double(index) * 0.15 - CACurrentMediaTime()
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                await pipeline.append(value)
            }
            await pipeline.setFinalContent(text)
            let deadline = CACurrentMediaTime() + 10
            while !idle && CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try await settle(window, milliseconds: 400)
            print("TYPEWRITER_WARM trial=\(trial) cpu_ms=\((cpu() - cpuStart) * 1000)")
            XCTAssertTrue(idle)
            let expected = MarkdownView.PreprocessedContent(parserResultNoMath: MarkdownParser().parse(text)).split().flatMap(\.blocks)
            XCTAssertEqual(blocks(window), expected)
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testLargePrefixDelivery() async throws {
        for trial in 0..<3 {
            let prefix = "<details type=\"reasoning\"><summary>Thinking</summary>" + String(repeating: sentence, count: 1500) + "</details>\n\n"
            var output = "", idle = false
            let pipeline = StreamingPipeline { value in
                if value.isActive { output = value.displayContent } else { idle = true }
            }
            await pipeline.beginWithPrefix(prefix)
            let started = CACurrentMediaTime(), cpuStart = cpu()
            var input = prefix
            for _ in 0..<100 {
                input += "Invented answer. "
                await pipeline.append(input)
                try await Task.sleep(for: .milliseconds(20))
            }
            let pending = input.count - output.count, done = CACurrentMediaTime()
            await pipeline.setFinalContent(input)
            for _ in 0..<2000 where !idle { try await Task.sleep(for: .milliseconds(2)) }
            print("IOS_BENCH prefix trial=\(trial) prefix_chars=\(prefix.count) cpu_ms=\((cpu()-cpuStart)*1000) elapsed_ms=\((CACurrentMediaTime()-started)*1000) pending=\(pending) finish_ms=\((CACurrentMediaTime()-done)*1000)")
            XCTAssertTrue(idle); XCTAssertEqual(output, input)
        }
    }
    func testRealRendererCorrectnessAndCost() async throws {
        let ordered = (1...9).map { "1. Item \($0). " + sentence }.joined(separator: "\n\n")
        let code = (1...120).map { "let observation\($0) = \($0) // synthetic" }.joined(separator: "\n")
        let samples = [
            ("plain", String(repeating: sentence, count: 7)),
            ("ordered", ordered),
            ("tilde", "~~~swift\n" + code + "\n~~~"),
            ("backtick", "```swift\n" + code + "\n```"),
            ("long_prose", (1...180).map { "Section \($0). " + sentence + "\n\n" }.joined()),
            ("large_prose", (1...1250).map { "Section \($0). " + sentence + "\n\n" }.joined()),
            ("single_paragraph", String(repeating: sentence, count: 300)),
            ("long_ordered", (1...100).map { "1. Item \($0). " + sentence }.joined(separator: "\n\n")),
            ("nested", "> A quote\n>\n> 1. First\n> 1. Second\n\n- One\n  - Nested\n\n[Guide][ref]\n\n[ref]: https://example.com\n\nUnicode 🔭 café e\u{301} 星"),
        ]
        for (name, text) in samples {
            let state = RenderState(), window = try host(state)
            try await settle(window)
            let probe = FrameProbe(); probe.start()
            let started = CACurrentMediaTime(), cpuStart = cpu()
            var codeIdentities = Set<ObjectIdentifier>()
            let step = max(20, text.count / 160)
            for count in stride(from: step, to: text.count, by: step) {
                state.text = String(text.prefix(count))
                try await Task.sleep(for: .milliseconds(30))
                for view in views(window).compactMap({ $0 as? CodeView }) { codeIdentities.insert(ObjectIdentifier(view)) }
            }
            state.text = text
            try await settle(window, milliseconds: 600)
            let streamingBlocks = blocks(window)
            let expected = MarkdownView.PreprocessedContent(parserResultNoMath: MarkdownParser().parse(text)).split().flatMap(\.blocks)
            let scroll = try XCTUnwrap(views(window).compactMap { $0 as? UIScrollView }.first)
            let height = scroll.contentSize.height
            let beforeIDs = views(window).compactMap { $0 as? MarkdownTextView }.map(ObjectIdentifier.init)
            let beforeCodeIDs = views(window).compactMap { $0 as? CodeView }.map(ObjectIdentifier.init)
            let gaps = zip(probe.times, probe.times.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            probe.stop()
            let activeCPU = (cpu()-cpuStart)*1000
            state.streaming = false
            try await settle(window, milliseconds: 1000)
            let afterIDs = views(window).compactMap { $0 as? MarkdownTextView }.map(ObjectIdentifier.init)
            let afterCodeIDs = views(window).compactMap { $0 as? CodeView }.map(ObjectIdentifier.init)
            print("IOS_BENCH renderer=\(name) chars=\(text.count) cpu_ms=\(activeCPU) elapsed_ms=\((CACurrentMediaTime()-started)*1000) frame_n=\(gaps.count) gap_p95_ms=\(gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count-1)*0.95)]) gaps_over50=\(gaps.filter { $0 > 50 }.count) gap_max_ms=\(gaps.last ?? 0) exact_stream_AST=\(streamingBlocks == expected) height_delta=\(scroll.contentSize.height-height) identities_stable=\(beforeIDs == afterIDs)")
            #if !QA_BASELINE
            XCTAssertEqual(streamingBlocks, expected, name)
            XCTAssertEqual(beforeIDs, afterIDs, name)
            XCTAssertEqual(beforeCodeIDs, afterCodeIDs, "Code view " + name)
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1, name)
            if name == "tilde" || name == "backtick" {
                XCTAssertEqual(codeIdentities.count, 1, "Code view stays alive while tokens arrive")
                let code = try XCTUnwrap(views(window).compactMap { $0 as? CodeView }.first)
                let colors = try XCTUnwrap(Mirror(reflecting: code).children.first { $0.label == "highlightMap" }?.value as? CodeHighlighter.HighlightMap)
                XCTAssertFalse(colors.isEmpty, "Finished Swift code is syntax highlighted")
            }
            #endif
            XCTAssertEqual(blocks(window), expected, "Final " + name)
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testFinalReasoningDoesNotBlankAnswer() async throws {
        for trial in 0..<10 {
            let state = RenderState(); state.assistant = true
            let window = try host(state)
            state.text = "An invented copper telescope stays visible through completion."
            try await settle(window, milliseconds: 400)
            XCTAssertTrue(rendered(window).contains("copper telescope"))
            var blankFrames = 0, frames = 0
            let probe = FrameProbe()
            probe.observe = { frames += 1; if !self.rendered(window).contains("copper telescope") { blankFrames += 1 } }
            probe.start()
            state.text = "<details type=\"reasoning\" done=\"true\"><summary>Thinking</summary>Trial \(trial). " + String(repeating: sentence, count: 1500) + "</details>\n\n" + state.text
            state.streaming = false
            try await settle(window, milliseconds: 1000)
            probe.stop()
            print("IOS_BENCH final_reasoning trial=\(trial) observed_frames=\(frames) blank_frames=\(blankFrames)")
            #if !QA_BASELINE
            XCTAssertEqual(blankFrames, 0)
            #endif
            XCTAssertTrue(rendered(window).contains("copper telescope"))
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testMathAndPreviewCompletion() async throws {
        let samples = [
            ("math", "Synthetic equation $x^2$ and $$\\frac{a}{b}$$."),
            ("html", "Before preview.\n\n```html\n<div style='padding:20px'>Synthetic card</div>\n```\n\nAfter preview."),
            ("svg", "Before preview.\n\n```svg\n<svg xmlns='http://www.w3.org/2000/svg' width='180' height='60'><rect width='180' height='60' fill='blue'/></svg>\n```\n\nAfter preview."),
            ("mermaid", "Before preview.\n\n```mermaid\nflowchart LR\n A[Invented] --> B[Result]\n```\n\nAfter preview."),
            ("python", "Before preview.\n\n```python\nprint('Synthetic result')\n```\n\nAfter preview.")
        ]
        for (name, text) in samples {
            let state = RenderState(), window = try host(state)
            for count in stride(from: 10, to: text.count, by: 10) {
                state.text = String(text.prefix(count))
                try await Task.sleep(for: .milliseconds(30))
            }
            state.text = text
            try await settle(window, milliseconds: 500)
            state.streaming = false
            try await settle(window, milliseconds: 1500)
            let finalText = rendered(window)
            XCTAssertTrue(finalText.contains(name == "math" ? "Synthetic equation" : "After preview"), name)
            if name == "math" {
                var equations = 0
                for view in views(window).compactMap({ $0 as? MarkdownTextView }) {
                    let text = view.textView.attributedText
                    text.enumerateAttribute(NSAttributedString.Key("mathLatexContent"), in: NSRange(location: 0, length: text.length)) { value, _, _ in
                        if value != nil { equations += 1 }
                    }
                }
                print("IOS_BENCH math_rendered_equations=\(equations)")
                XCTAssertEqual(equations, 2, "Both equations must render, not just retain raw LaTeX")
            }
            print("IOS_BENCH preview=\(name) text_survives=true native_views=\(views(window).count)")
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            attachment.name = "Synthetic " + name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }
}
