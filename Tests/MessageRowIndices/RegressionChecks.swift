import XCTest
import SwiftUI

@MainActor final class RegressionChecks: XCTestCase {
    private func withSubject(_ operation: (RowFixtureModel, RowFixtureRecorder, UIWindow) async -> Void) async {
        let model = RowFixtureModel(), recorder = RowFixtureRecorder()
        model.messages = (0..<20).map { ChatMessage(id: "invented-\($0)") }
        let host = UIHostingController(rootView: RowIndexSubject(viewModel: model, recorder: recorder))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        await settle()
        XCTAssertEqual(recorder.slots["invented-11"], RowFixtureSlot(index: 11, drawn: true))
        await operation(model, recorder, window)
        window.isHidden = true
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    private func picture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMiddleReplacementKeepsVisibleIndex() async {
        await withSubject { model, recorder, window in
            picture(window, name: "synthetic-before-replacement")
            model.messages[11] = ChatMessage(id: "invented-replacement")
            await settle()
            picture(window, name: "synthetic-after-replacement")
            XCTAssertEqual(recorder.slots["invented-replacement"], RowFixtureSlot(index: 11, drawn: true))
        }
    }

    func testReorderKeepsVisibleIndex() async {
        await withSubject { model, recorder, _ in
            model.messages.swapAt(11, 16)
            await settle()
            XCTAssertEqual(recorder.slots["invented-16"], RowFixtureSlot(index: 11, drawn: true))
            XCTAssertEqual(recorder.slots["invented-11"], RowFixtureSlot(index: 16, drawn: false))
        }
    }

    func testInsertAndRemoveKeepCurrentPositions() async {
        await withSubject { model, recorder, _ in
            model.messages.insert(ChatMessage(id: "invented-inserted"), at: 0)
            await settle()
            XCTAssertEqual(recorder.slots["invented-11"], RowFixtureSlot(index: 12, drawn: true))
            model.messages.remove(at: 0)
            await settle()
            XCTAssertEqual(recorder.slots["invented-11"], RowFixtureSlot(index: 11, drawn: true))
        }
    }

    func testAssistantRunsKeepGlobalIndices() async {
        await withSubject { model, recorder, _ in
            for index in model.messages.indices { model.messages[index].role = index % 4 == 0 ? .user : .assistant }
            await settle()
            for index in model.messages.indices {
                XCTAssertEqual(recorder.slots["invented-\(index)"]?.index, index)
            }
            XCTAssertEqual(recorder.slots["invented-17"]?.drawn, true) // Entire last turn remains drawn.
            XCTAssertEqual(recorder.slots["invented-9"]?.drawn, false)
        }
    }

    func testLeadingAssistantAndEmptyHistory() async {
        await withSubject { model, recorder, _ in
            model.messages[0].role = .assistant
            await settle()
            XCTAssertEqual(recorder.slots["invented-0"]?.index, 0)
            model.messages = []
            await settle()
            model.messages = [ChatMessage(id: "invented-only", role: .assistant)]
            await settle()
            XCTAssertEqual(recorder.slots["invented-only"], RowFixtureSlot(index: 0, drawn: true))
        }
    }

    func testStreamingAndEditingRowsStayDrawn() async {
        await withSubject { model, recorder, _ in
            model.streamingStore.isActive = true
            model.streamingStore.streamingMessageId = "invented-3"
            model.editingMessageId = "invented-4"
            await settle()
            XCTAssertEqual(recorder.slots["invented-3"], RowFixtureSlot(index: 3, drawn: true))
            XCTAssertEqual(recorder.slots["invented-4"], RowFixtureSlot(index: 4, drawn: true))
            model.streamingStore.isActive = false
            model.editingMessageId = nil
            await settle()
            XCTAssertEqual(recorder.slots["invented-3"]?.drawn, false)
            XCTAssertEqual(recorder.slots["invented-4"]?.drawn, false)
        }
    }
}
