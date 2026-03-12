import XCTest
@testable import Open_UI

/// Unit tests for the core data models: ``Conversation``, ``ChatMessage``,
/// ``AIModel``, and ``ChatSourceReference``.
final class ModelTests: XCTestCase {

    // MARK: - Conversation Tests

    func testConversationInitialisesWithDefaults() {
        let conversation = Conversation(title: "Test Chat")

        XCTAssertFalse(conversation.id.isEmpty)
        XCTAssertEqual(conversation.title, "Test Chat")
        XCTAssertFalse(conversation.pinned)
        XCTAssertFalse(conversation.archived)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertTrue(conversation.tags.isEmpty)
        XCTAssertNil(conversation.model)
        XCTAssertNil(conversation.systemPrompt)
        XCTAssertNil(conversation.shareId)
        XCTAssertNil(conversation.folderId)
    }

    func testConversationEqualityByID() {
        let id = "test-id-123"
        let conv1 = Conversation(id: id, title: "First Title")
        let conv2 = Conversation(id: id, title: "Different Title")

        XCTAssertEqual(conv1, conv2, "Conversations with the same ID should be equal")
    }

    func testConversationInequalityByID() {
        let conv1 = Conversation(title: "Same Title")
        let conv2 = Conversation(title: "Same Title")

        XCTAssertNotEqual(conv1, conv2, "Conversations with different IDs should not be equal")
    }

    func testConversationHashable() {
        let id = "hash-test"
        let conv1 = Conversation(id: id, title: "A")
        let conv2 = Conversation(id: id, title: "B")

        var set = Set<Conversation>()
        set.insert(conv1)
        set.insert(conv2)

        XCTAssertEqual(set.count, 1, "Same-ID conversations should hash to the same bucket")
    }

    func testConversationMutability() {
        var conversation = Conversation(title: "Original")
        conversation.title = "Updated"
        conversation.pinned = true
        conversation.archived = true

        XCTAssertEqual(conversation.title, "Updated")
        XCTAssertTrue(conversation.pinned)
        XCTAssertTrue(conversation.archived)
    }

    // MARK: - ChatMessage Tests

    func testChatMessageInitialisesWithDefaults() {
        let message = ChatMessage(role: .user, content: "Hello")

        XCTAssertFalse(message.id.isEmpty)
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Hello")
        XCTAssertFalse(message.isStreaming)
        XCTAssertTrue(message.attachmentIds.isEmpty)
        XCTAssertTrue(message.sources.isEmpty)
        XCTAssertTrue(message.statusHistory.isEmpty)
        XCTAssertNil(message.model)
        XCTAssertNil(message.error)
    }

    func testChatMessageRoles() {
        let userMsg = ChatMessage(role: .user, content: "")
        let assistantMsg = ChatMessage(role: .assistant, content: "")
        let systemMsg = ChatMessage(role: .system, content: "")

        XCTAssertEqual(userMsg.role, .user)
        XCTAssertEqual(assistantMsg.role, .assistant)
        XCTAssertEqual(systemMsg.role, .system)
    }

    func testChatMessageEqualityByID() {
        let id = "msg-123"
        let msg1 = ChatMessage(id: id, role: .user, content: "Hello")
        let msg2 = ChatMessage(id: id, role: .assistant, content: "Hi there")

        XCTAssertEqual(msg1, msg2, "Messages with the same ID should be equal")
    }

    func testChatMessageWithError() {
        let error = ChatMessageError(content: "Rate limit exceeded")
        let message = ChatMessage(role: .assistant, content: "Partial response", error: error)

        XCTAssertNotNil(message.error)
        XCTAssertEqual(message.error?.content, "Rate limit exceeded")
    }

    func testChatMessageWithSources() {
        let source = ChatSourceReference(
            id: "src-1",
            title: "Wikipedia",
            url: "https://en.wikipedia.org",
            snippet: "Test snippet",
            type: "web"
        )
        let message = ChatMessage(
            role: .assistant,
            content: "Based on sources...",
            sources: [source]
        )

        XCTAssertEqual(message.sources.count, 1)
        XCTAssertEqual(message.sources.first?.title, "Wikipedia")
    }

    // MARK: - AIModel Tests

    func testAIModelInitialisesWithDefaults() {
        let model = AIModel(id: "gpt-4", name: "GPT-4")

        XCTAssertEqual(model.id, "gpt-4")
        XCTAssertEqual(model.name, "GPT-4")
        XCTAssertFalse(model.isMultimodal)
        XCTAssertTrue(model.supportsStreaming)
        XCTAssertFalse(model.supportsRAG)
        XCTAssertNil(model.contextLength)
        XCTAssertNil(model.profileImageURL)
        XCTAssertTrue(model.toolIds.isEmpty)
    }

    func testAIModelShortName() {
        let model1 = AIModel(id: "1", name: "openai/gpt-4-turbo")
        XCTAssertEqual(model1.shortName, "gpt-4-turbo")

        let model2 = AIModel(id: "2", name: "Claude 3.5 Sonnet")
        XCTAssertEqual(model2.shortName, "Claude 3.5 Sonnet")

        let model3 = AIModel(id: "3", name: "org/provider/model-name")
        XCTAssertEqual(model3.shortName, "model-name")
    }

    func testAIModelEquality() {
        let model1 = AIModel(id: "gpt-4", name: "GPT-4")
        let model2 = AIModel(id: "gpt-4", name: "GPT-4 Updated")

        XCTAssertEqual(model1, model2, "Models with same ID should be equal")
    }

    // MARK: - MessageRole Tests

    func testMessageRoleRawValues() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }

    func testMessageRoleFromRawValue() {
        XCTAssertEqual(MessageRole(rawValue: "user"), .user)
        XCTAssertEqual(MessageRole(rawValue: "assistant"), .assistant)
        XCTAssertEqual(MessageRole(rawValue: "system"), .system)
        XCTAssertNil(MessageRole(rawValue: "invalid"))
    }

    // MARK: - HealthCheckResult Tests

    func testHealthCheckResultCases() {
        // Verify all cases exist (compile-time check)
        let cases: [HealthCheckResult] = [.healthy, .unhealthy, .proxyAuthRequired, .unreachable]
        XCTAssertEqual(cases.count, 4)
    }
}
