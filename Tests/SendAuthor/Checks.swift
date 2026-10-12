import Foundation

@main struct Checks {
 @MainActor static func main() {
   var checks=0
   for owner in [nil,"invented-viewer","invented-owner"] {
    for viewer in [nil,"invented-viewer"] {
     let model=Subject();model.conversation=Conversation(owner:owner);model.viewerUserId=viewer
     let expected=(owner != nil && viewer != nil && owner != viewer) ? viewer : nil
     let author=model.append();precondition(author == expected);checks += 1
     precondition(model.conversation?.messages.count == 1);checks += 1
     precondition(model.conversation?.messages.first?.authorId == expected);checks += 1
     precondition(model.conversation?.messages.first?.isStreaming == true);checks += 1
    }
   }
   let empty=Subject();precondition(empty.append()==nil);checks += 1
   precondition(empty.conversation==nil);checks += 1
   print("\(checks)/\(checks) synthetic author/exclusivity checks passed")
 }
}
