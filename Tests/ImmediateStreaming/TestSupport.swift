import Foundation

struct ChatStatusUpdate {
    let action: String
    let done: Bool?
}
struct ChatSourceReference {
    let id: String?
    let url: String?
}
struct ChatMessageError {}
enum Haptics {
    static func streamingTick() {}
    static func streamingComplete() {}
}
