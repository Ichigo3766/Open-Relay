import Foundation
enum TLSChallengeHandler {static func isClientCertificateError(_ error:Error)->Bool{false}}
struct Item:Sendable {let id:String;var type:Kind = .file;var isTranscribing=false;enum Kind {case audio,file}}
struct QueuedMessage:Sendable {let id:UUID;let text:String}
struct ChatMessageError:Sendable {let content:String}
struct ChatStatusUpdate:Sendable {let action:String;let description:String;let done:Bool}
struct Network:Sendable {let conversationCacheScope:String?="invented-scope"}
struct API:Sendable {let network=Network()}
struct Manager:Sendable {let apiClient=API()}
struct Logger {func info(_ value:String){}}
@MainActor final class DictationRecoveryStore {
 static let shared=DictationRecoveryStore()
 struct Entry {var draft:String;var recording:Int?}
 func load(_ context:Int)throws->Entry?{nil}
 func save(_ entry:Entry,for context:Int)throws{}
 func saveDraft(_ text:String,for context:Int)throws{}
}
@MainActor final class Subject {
 enum Reason {case busy,failed,empty,webSearch,needsInput,queued}
 INSERT_INPUT
 var queuedDraftId:UUID?
 var joinedChatRoomId:String?
 func emitTyping(_ value:Bool){}
 var pendingSendAttempt:UUID?
 var isRecoveringSendAcknowledgement=false
 var isCompactingContext=false,contextNeedsRefresh=false,isSavingChatVariables=false,isCreatingConversation=false,isCreatingNoteChat=false
 var dictationDraftContext:Int?=nil,toolsHaveLoaded=true,isVoiceMode=false,enableMessageQueue=true,isStreaming=false
 var attachments=[Item](),selectedKnowledgeItems=[Item](),selectedReferenceChats=[Item](),selectedNotes=[Item](),selectedSkillIds=[String]()
 var errorMessage:String?,toolConnectionRequested:Int?,lastSendBlockReason:Reason?
 var messageQueue=[QueuedMessage](),manager:Manager?=Manager(),streamingSessionId=1,activeTaskIds=[String]()
 var hasFinishedStreaming=false
 var transportCalls=0,preflightCalls=0,recoveries=0
 var receiptLost=false,preflightRejected=false,finishBeforeReceipt=false
 let logger=Logger()
 func restoreDetailsForAction()async->Bool{true}
 func ensureToolsLoaded()async{}
 func authorizeWebSearch()async->Bool {
  preflightCalls+=1;let delay=preflightCalls==1 ? 10 : 50
  try? await Task.sleep(for:.milliseconds(delay));return !preflightRejected
 }
 func checkToolConnections(ignoreDraftAndBranch:Bool)async->Bool{true}
 func stopStreaming(stopAllChatTasks:Bool){isStreaming=false}
 func sendBlocked(_ reason:Reason,_ detail:String)->Bool{lastSendBlockReason=reason;return false}
 func updateAssistantMessage(id:String,content:String,isStreaming:Bool,error:ChatMessageError?){self.isStreaming=isStreaming}
 INSERT_CLEANUP
 func stopSwitchStatusPolling(){}
 func cancelLiveAskUser(){}
 let toolEventPrompts=Prompts()
 struct Prompts{func cancelAll(){}}
 var isExternallyStreaming=false
 func appendStatusUpdate(id:String,status:ChatStatusUpdate){}
 func startRecoveryTimer(assistantMessageId:String,chatId:String?){recoveries+=1}
 INSERT_DRAIN
 var pendingQueueDrains=0
 INSERT_PARSE
 INSERT_SEND_PREFIX
        let processedAttachments=attachments
        let originalAttachments=attachments
        let currentKnowledgeItems=selectedKnowledgeItems,currentReferenceChats=selectedReferenceChats,currentNotes=selectedNotes,currentSkillIds=selectedSkillIds
        INSERT_CAPTURE
        isStreaming=true
        hasFinishedStreaming=false
        transportCalls+=1
        INSERT_SUBMISSION
        let sendScope:String?="invented-scope",sendSessionId=1,assistantMessageId="invented-assistant",effectiveChatId:String?="invented-chat"
        func complete()async {
            INSERT_TASK_DEFER
            do {
                try await Task.sleep(for:.milliseconds(120))
                if finishBeforeReceipt {cleanupStreaming()}
                if receiptLost {throw URLError(.networkConnectionLost)}
                let json:[String:Any]=["task_ids":["invented-task"]]
                INSERT_ACK
            } catch {
                INSERT_CATCH
            }
        }
        await complete()
        return true
    }
}
@main struct Checks {
 @MainActor static func main()async {
  let scenario=CommandLine.arguments[1]
  if scenario=="batch" || scenario=="batch-edited" || scenario=="unrelated" {
   let vm=Subject();vm.isStreaming=true;vm.inputText="Invented first queued lantern.";_ = await vm.sendMessage()
   if scenario=="unrelated" {vm.messageQueue.removeAll();_ = await vm.sendMessage(directText:"Invented unrelated queue item.")}
   else {vm.inputText="Invented last queued lantern.";_ = await vm.sendMessage()}
   vm.cleanupStreaming();vm.drainMessageQueue(after:80_000_000)
   if scenario=="batch-edited" {vm.inputText="Invented later edit.";vm.inputText="Invented last queued lantern."}
   try? await Task.sleep(for:.milliseconds(400))
   let expected=scenario=="batch" ? "" : scenario=="unrelated" ? "Invented first queued lantern." : "Invented last queued lantern."
   guard vm.transportCalls==1 && vm.inputText==expected else{print("FAIL: batch acknowledgment must consume only its owned composer draft");exit(1)}
   print("PASS: \(scenario) composer ownership");return
  }
  if scenario=="handoff" {
   let vm=Subject();vm.inputText="Invented handoff lantern.";vm.isStreaming=true
   _ = await vm.sendMessage();vm.cleanupStreaming();vm.drainMessageQueue(after:300_000_000)
   _ = await vm.sendMessage();try? await Task.sleep(for:.milliseconds(600))
   print("Synthetic handoff started=\(vm.transportCalls) queued=\(vm.messageQueue.count)")
   guard vm.transportCalls==1 && vm.messageQueue.isEmpty else{print("FAIL: queued handoff must not submit and requeue the draft");exit(1)}
   print("PASS: queue handoff reserves draft once");return
  }
  if scenario=="lifecycle" {
   var count=0
   func check(_ value:Bool,_ label:String){count+=1;if !value{print("FAIL: "+label);exit(1)}}
   let lost=Subject();lost.inputText="Invented pending lantern.";lost.receiptLost=true
   _ = await lost.sendMessage()
   check(lost.pendingSendAttempt != nil && lost.isRecoveringSendAcknowledgement,"unknown receipt retains reservation")
   _ = await lost.sendMessage()
   check(lost.transportCalls==1 && lost.messageQueue.isEmpty,"second tap during recovery cannot enqueue submitted draft")
   lost.cleanupStreaming()
   check(lost.pendingSendAttempt==nil && !lost.isRecoveringSendAcknowledgement,"definitive stream end releases reservation")
   lost.receiptLost=false;_ = await lost.sendMessage()
   check(lost.transportCalls==2 && lost.inputText.isEmpty,"explicit retry after recovery may send retained draft")
   let queued=Subject();queued.inputText="Invented first lantern.";_ = await queued.sendMessage()
   check(queued.inputText.isEmpty && queued.pendingSendAttempt==nil,"valid receipt consumes and releases first draft")
   queued.inputText="Invented first lantern.";_ = await queued.sendMessage()
   check(queued.messageQueue.count==1,"newly typed identical text after receipt is a new intentional message")
   _ = await queued.sendMessage();check(queued.messageQueue.count==1,"unchanged queued draft cannot be queued twice")
   queued.inputText="Invented different lantern.";_ = await queued.sendMessage()
   queued.inputText="Invented first lantern.";_ = await queued.sendMessage()
   check(queued.messageQueue.count==3,"editing and returning to identical text creates a distinct draft")
   queued.messageQueue.removeLast();_ = await queued.sendMessage()
   check(queued.messageQueue.count==3,"removing queued item allows explicit requeue")
   _ = await queued.sendMessage(directText:"Invented first lantern.")
   check(queued.messageQueue.count==4,"explicit direct sends do not deduplicate message content")
   let rejected=Subject();rejected.inputText="Invented rejected lantern.";rejected.preflightRejected=true
   _ = await rejected.sendMessage();check(rejected.pendingSendAttempt==nil && rejected.transportCalls==0,"preflight rejection releases reservation")
   let finished=Subject();finished.inputText="Invented finished lantern.";finished.receiptLost=true;finished.finishBeforeReceipt=true
   _ = await finished.sendMessage()
   check(finished.pendingSendAttempt==nil && finished.recoveries==0 && !finished.isRecoveringSendAcknowledgement,"late receipt failure cannot reserve an already finished stream")
   let burst=Subject();burst.inputText="Invented burst lantern.";let tasks=(0..<64).map{_ in Task{await burst.sendMessage()}}
   for task in tasks {_ = await task.value}
   check(burst.transportCalls==1 && burst.messageQueue.isEmpty,"64 overlapping sends reserve one submission")
   print("Passed \(count) send reservation lifecycle checks");return
  }
  let vm=Subject();vm.inputText="Invent a paper lantern."
  if scenario=="queue" || scenario=="queue-late"{vm.isStreaming=true}
  if scenario=="lost"{vm.receiptLost=true}
  let first=Task {await vm.sendMessage()}
  try? await Task.sleep(for:.milliseconds(scenario=="lost" || scenario=="queue-late" ? 160 : 1))
  let second=Task {await vm.sendMessage()}
  let a=await first.value,b=await second.value
  print("Synthetic scenario=\(scenario) started=\(vm.transportCalls) queued=\(vm.messageQueue.count) first=\(a) second=\(b) recovery=\(vm.recoveries)")
  let okay=scenario=="queue" || scenario=="queue-late" ? vm.transportCalls==0 && vm.messageQueue.count==1 : vm.transportCalls==1 && vm.messageQueue.isEmpty
  if !okay {print("FAIL: one unchanged draft must not be submitted or queued twice");exit(1)}
  print("PASS: unchanged draft reserved once")
 }
}
