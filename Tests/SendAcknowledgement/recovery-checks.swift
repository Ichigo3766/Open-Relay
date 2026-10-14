import Foundation
@MainActor final class Subject {
    let store:DictationRecoveryStore
    var dictationDraftContext:DictationContext?
    var inputText="Invented durable draft"
    var errorMessage:String?
    enum Reason {case failed}
    func sendBlocked(_ reason:Reason,_ detail:String)->Bool{false}
    init(_ directory:URL){store=DictationRecoveryStore(directory:directory)}
    func checkpoint()->Bool {
        let draftBeforeSend=inputText
        INSERT_SNAPSHOT
        return true
    }
}
@main struct Checks {
    @MainActor static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var count=0
        func check(_ ok:Bool,_ label:String){count+=1;if !ok{print("FAIL: "+label);exit(1)}}
        let context=DictationContext(server:"https://example.invalid",account:"invented-account",conversation:nil)
        let subject=Subject(root.appendingPathComponent(UUID().uuidString));subject.dictationDraftContext=context
        check(subject.checkpoint(),"Send checkpoints an ordinary draft")
        let restarted=DictationRecoveryStore(directory:subject.store.directory)
        check(try restarted.load(context)?.draft==subject.inputText,"ordinary draft survives store recreation")
        var saved=context;saved.conversation="invented-created-chat"
        try subject.store.move(from:context,to:saved)
        check(try restarted.load(saved)?.draft==subject.inputText,"draft follows new server chat identity")
        try restarted.saveDraft("Invented edit while sending",for:saved)
        check(try restarted.load(saved)?.draft=="Invented edit while sending","checkpoint tracks later edits")
        try restarted.saveDraft("",for:saved)
        check(try restarted.load(saved)==nil,"cleared ordinary draft removes empty checkpoint")
        try restarted.saveDraft("Invented ordinary typing",for:saved)
        check(try restarted.load(saved)==nil,"typing after ACK does not create per-keystroke recovery writes")
        let voice=Subject(root.appendingPathComponent(UUID().uuidString));voice.dictationDraftContext=context
        let recording=try voice.store.begin(context,draft:voice.inputText,engine:"invented-engine")
        check(voice.checkpoint(),"checkpoint preserves recording-backed draft")
        check(try voice.store.load(context)?.recording?.id==recording.id,"checkpoint retains pending audio receipt")
        try voice.store.saveDraft("",for:context)
        check(try voice.store.load(context)?.recording?.id==recording.id,"manual clearing cannot delete pending audio recovery")
        let invalid=root.appendingPathComponent(UUID().uuidString);try Data("Invented obstruction".utf8).write(to:invalid)
        let blocked=Subject(invalid);blocked.dictationDraftContext=context
        check(!blocked.checkpoint() && blocked.inputText=="Invented durable draft","storage failure blocks send and preserves composer")
        print("Passed \(count) durable draft checks")
    }
}
