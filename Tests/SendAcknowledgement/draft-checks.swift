import Foundation
struct Item:Sendable {let id:String}
struct ChatMessageError:Sendable {let content:String}
struct Network:Sendable {var conversationCacheScope:String?="invented-scope"}
struct API:Sendable {var network=Network()}
struct Manager:Sendable {var apiClient=API()}
@MainActor final class Subject {
    var manager:Manager?=Manager()
    var inputText="Invented original draft"
    var attachments=[Item(id:"invented-file")],selectedKnowledgeItems=[Item(id:"invented-knowledge")],selectedReferenceChats=[Item(id:"invented-reference")],selectedNotes=[Item(id:"invented-note")]
    var selectedSkillIds=["invented-skill"]
    var queuedDraftId:UUID?
    var pendingSendAttempt:UUID?
    var streamingSessionId=1
    var activeTaskIds=[String]()
    var errors=0,cleanups=0
    var hasFinishedStreaming=false
    func drainMessageQueue(after:UInt64){}
    func updateAssistantMessage(id:String,content:String,isStreaming:Bool,error:ChatMessageError?){errors+=1}
    func cleanupStreaming(){cleanups+=1}
    INSERT_PARSE
    func acknowledge(_ json:[String:Any],directText:String?=nil,fromQueue:Bool=false,queuedComposerId:UUID?=nil) {
        let sendScope:String?="invented-scope",sendSessionId=1,assistantMessageId="invented-assistant"
        let sendAttempt=pendingSendAttempt ?? UUID()
        let currentText=directText ?? "Invented original draft",draftBeforeSend="Invented original draft"
        let originalAttachments=[Item(id:"invented-file")],currentKnowledgeItems=[Item(id:"invented-knowledge")],currentReferenceChats=[Item(id:"invented-reference")],currentNotes=[Item(id:"invented-note")],currentSkillIds=["invented-skill"]
        INSERT_ACCEPT
    }
}
@main struct Checks {
    @MainActor static func main() async {
        var count=0
        func check(_ ok:Bool,_ label:String){count+=1;if !ok{print("FAIL: "+label);exit(1)}}
        let responses:[[String:Any]]=[["task_ids":["invented-task"]],["task_id":"invented-task"],["status":true,"task_ids":[]],["choices":[["message":["content":"Invented answer"]]]]]
        for json in responses {
            let vm=Subject();vm.pendingSendAttempt=UUID();vm.acknowledge(json)
            check(vm.inputText.isEmpty,"recognized ACK consumes unchanged draft")
            check(vm.attachments.isEmpty && vm.selectedKnowledgeItems.isEmpty && vm.selectedReferenceChats.isEmpty && vm.selectedNotes.isEmpty && vm.selectedSkillIds.isEmpty,"ACK consumes only sent selections")
            check(vm.pendingSendAttempt==nil,"ACK releases pending-send gate")
        }
        for json in [["error":"Invented rejection"],["detail":"Invented failure"],["status":false],[:],["raw":"Invented proxy page"]] as [[String:Any]] {
            let vm=Subject();vm.acknowledge(json)
            check(vm.inputText=="Invented original draft","rejected or unrecognized response preserves draft")
            check(vm.attachments.count==1 && vm.selectedNotes.count==1,"failed ACK keeps selected files")
            check(vm.errors==1 && vm.cleanups==1,"failed ACK is visible")
        }
        let edited=Subject();edited.inputText+=" and a new edit";edited.attachments.append(Item(id:"invented-new-file"));edited.selectedNotes.append(Item(id:"invented-new-note"));edited.acknowledge(responses[0])
        check(edited.inputText.hasSuffix("new edit"),"ACK preserves edits made while sending")
        check(edited.attachments.map(\.id)==["invented-new-file"] && edited.selectedNotes.map(\.id)==["invented-new-note"],"ACK preserves new attachments and notes")
        let direct=Subject();direct.acknowledge(responses[0],directText:"Invented unrelated suggestion")
        check(!direct.inputText.isEmpty,"direct suggestion leaves unrelated composer draft")
        let matching=Subject();matching.acknowledge(responses[0],directText:matching.inputText)
        check(matching.inputText.isEmpty,"direct send consumes the matching composer draft after ACK")
        let changedScope=Subject();changedScope.manager?.apiClient.network.conversationCacheScope="invented-new-scope";changedScope.acknowledge(responses[0])
        check(!changedScope.inputText.isEmpty && changedScope.attachments.count==1,"account change prevents old ACK from consuming draft")
        let newSession=Subject();newSession.streamingSessionId=2;newSession.acknowledge(responses[0])
        check(!newSession.inputText.isEmpty,"old stream acknowledgement cannot consume new draft")
        let cancelled=Subject();let task=Task{ @MainActor in try? await Task.sleep(for:.milliseconds(10));cancelled.acknowledge(responses[0])};task.cancel();await task.value
        check(!cancelled.inputText.isEmpty,"cancelled request leaves draft intact")
        print("Passed \(count) atomic draft checks")
    }
}
