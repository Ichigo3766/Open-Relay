import Foundation

@MainActor func verifyRenderGroups(_ check:(Bool,String)->Void) {
 for count in [0,1,2,3,12,1000,12000,100000] {
 let messages=(0..<count).map{ChatMessage(id:"fictional-row-\($0)",role:$0%2==0 ? .user:.assistant,content:"An invented cardboard tower.")}
 let v=ChatRowVirtualizer();v.updateWidth(393)
 for i in messages.indices {v.report(id:messages[i].id,index:i,height:CGFloat(70+i%9)+0.25)}
 for start in [0,count/3,max(0,count-15)] {
 var r=Renderer(viewModel:Owner(messages:messages),drawnRange:count>0 ? start...min(start+8,count-1):nil,virtualizer:v)
 if count>12 {r.viewModel.streamingStore=Stream(isActive:true,streamingMessageId:messages[count/2].id);r.editingMessageId=messages[count/4].id}
 let items=r.items();var indices:[Int]=[]
 let positions=Dictionary(uniqueKeysWithValues:messages.enumerated().map{($0.element.id,$0.offset)})
 for (offset,item) in items.enumerated() {
 if let rows=item.rows {
 indices+=rows.map(\.index)
 check(!rows.isEmpty,"nonempty turn")
 check(rows.allSatisfy{messages[$0.index].id==$0.message.id},"global row indices")
 } else {
 guard case let .gap(id)=item.id else {fatalError("Wrong gap identity")}
 let lower=positions[id]!
 let upper=items[(offset+1)...].compactMap{$0.rows?.first?.index}.first ?? count
 indices+=Array(lower..<upper)
 let expected=(lower..<upper).reduce(CGFloat(0)){$0+v.height(for:messages[$1])}
 check(abs(item.height-expected)<0.001,"exact aggregated height")
 }
 }
 check(indices==Array(messages.indices),"every slot once in order")
 check(Set(items.map(\.id)).count==items.count,"unique typed stable IDs")
 if count>12 {
 let drawn=items.flatMap{$0.rows?.filter(\.isDrawn).map(\.index) ?? []}
 check(drawn.contains(count/2),"stream remains drawn")
 check(drawn.contains(count/4),"edited row remains drawn")
 check(drawn.contains(count-1),"last turn remains drawn")
 check(drawn.count<=18,"bounded ordinary turns")
 }
 }
 check(v.height(for:0..<0,messages:messages)==0,"empty gap")
 check(v.height(for:0..<(count+1),messages:messages)==0,"invalid upper bound")
 }
 // Leading replies, consecutive users, and multiple replies belong to whole turns.
 let roleSequences: [[MessageRole]] = [[.assistant,.assistant], [.assistant,.user,.assistant,.assistant,.user,.assistant], [.user,.user,.assistant,.assistant,.user]]
 for roles in roleSequences {
 let messages=roles.enumerated().map{ChatMessage(id:"fictional-group-\($0.offset)",role:$0.element,content:"An invented paper telescope.")}
 let v=ChatRowVirtualizer();v.updateWidth(393)
 for i in messages.indices {v.report(id:messages[i].id,index:i,height:CGFloat(80+i))}
 for visible in messages.indices {
 var r=Renderer(viewModel:Owner(messages:messages),drawnRange:visible...visible,virtualizer:v)
 r.editingMessageId=messages.first?.id
 r.viewModel.streamingStore=Stream(isActive:true,streamingMessageId:messages.last?.id)
 let items=r.items();let drawn=items.flatMap{$0.rows?.filter(\.isDrawn).map(\.index) ?? []}
 check(drawn.contains(visible),"nonalternating visible row")
 check(drawn.contains(0),"leading edited row")
 check(drawn.contains(messages.count-1),"nonalternating last stream")
 var slots:[Int]=[]
 for (offset,item) in items.enumerated() {
 if let rows=item.rows {slots+=rows.map(\.index)} else {
 guard case let .gap(id)=item.id,let lower=messages.firstIndex(where:{$0.id==id}) else {fatalError("Invalid gap")}
 let upper=items[(offset+1)...].compactMap{$0.rows?.first?.index}.first ?? messages.count
 slots+=Array(lower..<upper)
 check(abs(item.height-(lower..<upper).reduce(CGFloat(0)){$0+v.height(for:messages[$1])})<0.001,"nonalternating gap height")
 }
 }
 check(slots==Array(messages.indices),"nonalternating slots exactly once")
 check(Set(items.map(\.id)).count==items.count,"nonalternating identities")
 }
 }
 let replies=(0..<402).map{ChatMessage(id:"invented-reply-\($0)",role:[$0==0,$0==200,$0==400].contains(true) ? .user:.assistant,content:"An invented multi-reply exhibit.")}
 let v=ChatRowVirtualizer();v.updateWidth(393)
 var r=Renderer(viewModel:Owner(messages:replies),drawnRange:40...45,virtualizer:v)
 r.editingMessageId=replies[260].id
 r.viewModel.streamingStore=Stream(isActive:true,streamingMessageId:replies[300].id)
 let rows=r.items().flatMap{$0.rows ?? []},drawn=rows.filter(\.isDrawn).map(\.index)
 check(drawn==Array(40...45)+[260,300,400,401],"many replies preserve per-row filtering")
 check(rows.count==402,"complete turn slots remain available")
 check(drawn.count==10,"large visible and forced turns keep offscreen replies light")
}
