import Foundation

@MainActor final class World {
    var messages: [ChatMessage]
    var heights: [CGFloat]
    let view = UIScrollView()
    let v = ChatRowVirtualizer()
    init(_ count: Int = 100) {
        messages=(0..<count).map { ChatMessage(id:"invented-row-\($0)",role: $0 % 2 == 0 ? .user : .assistant,content:"An invented comet.") }
        heights=Array(repeating:80,count:count)
        v.updateWidth(393);v.scrollView=view
        refresh()
    }
    func refresh() {
        var y:CGFloat=0
        for i in messages.indices { report(v, messages[i].id, i, y, heights[i], true);y+=heights[i] }
    }
    func anchor(_ index:Int, inside:CGFloat=31) {
        view.contentOffset.y=heights.prefix(index).reduce(0,+)+inside
        v.updateViewport(top:view.contentOffset.y,height:800);v.updateAnchor(messages:messages)
    }
    func change(_ index:Int,_ delta:CGFloat) { heights[index]+=delta;refresh() }
}
@main struct HeightChecks {
    @MainActor static func main() {
        var checks=0,failures=0
        func check(_ condition:Bool,_ name:String) { checks+=1;if !condition { failures+=1;print("FAIL",name) } }
        for anchor in [1,5,25,50,95] {
            let w=World();w.anchor(anchor);let initial=w.view.contentOffset.y
            w.change(0,40);check(abs(w.view.contentOffset.y-initial-40)<0.01,"above anchor \(anchor)")
            check(abs(w.v.consumeCompensation()-40)<0.01,"consumed delta")
            w.v.updateViewport(top:w.view.contentOffset.y,height:800);w.v.updateAnchor(messages:w.messages)
            let next=w.view.contentOffset.y;w.change(anchor,100)
            check(abs(w.view.contentOffset.y-next)<0.01,"anchor own growth")
            w.change(99,20);check(abs(w.view.contentOffset.y-next)<0.01,"below anchor")
            w.change(0,-20);check(abs(w.view.contentOffset.y-next+20)<0.01,"shrink above")
            check(abs(w.v.consumeCompensation()+20)<0.01,"combined delta")
            w.refresh();check(w.v.consumeCompensation()==0,"identical measurements")
        }
        let top=World();top.anchor(0,inside:0);top.change(0,90);check(top.view.contentOffset.y==0,"at top")
        let held=World();held.anchor(50);let heldOffset=held.view.contentOffset.y;held.v.hold(for:10);held.change(0,50);check(held.view.contentOffset.y==heldOffset,"hold")
        let absent=World();absent.v.scrollView=nil;absent.anchor(50);absent.change(0,50);check(absent.v.consumeCompensation()==0,"no view")
        for count in [12,100,1000] {
            let w=World(count);w.anchor(count/2);let initial=w.view.contentOffset.y
            for i in 0..<min(8,count/2) { w.change(i,CGFloat((i+1)*3)) }
            let expected=(0..<min(8,count/2)).reduce(CGFloat(0)){$0+CGFloat(($1+1)*3)}
            check(abs(w.view.contentOffset.y-initial-expected)<0.01,"multiple above \(count)")
        }
        let inserted=World();inserted.anchor(50);let origin=inserted.view.contentOffset.y
        inserted.messages.insert(ChatMessage(id:"invented-inserted",role:.user,content:"A new fictional comet."),at:20);inserted.heights.insert(80,at:20);inserted.refresh()
        _=inserted.v.updatedRange(messages:inserted.messages,current:nil)
        check(abs(inserted.view.contentOffset.y-origin-80)<0.01,"insertion above")
        inserted.v.updateViewport(top:inserted.view.contentOffset.y,height:800);inserted.v.updateAnchor(messages:inserted.messages)
        inserted.change(21,30);check(abs(inserted.view.contentOffset.y-origin-110)<0.01,"change after insertion")
        check(inserted.v.topVisibleIndex(messages:inserted.messages)==51,"index after insertion")
        let fractions=World();fractions.anchor(50);let fractionalStart=fractions.view.contentOffset.y
        for i in 0..<20 {fractions.heights[i]+=0.25};fractions.refresh()
        check(abs(fractions.view.contentOffset.y-fractionalStart-5)<0.01,"combined fractional growth above")
        fractions.v.updateViewport(top:fractions.view.contentOffset.y,height:800);fractions.v.updateAnchor(messages:fractions.messages)
        for i in 0..<20 {fractions.heights[i]-=0.25};fractions.refresh()
        check(abs(fractions.view.contentOffset.y-fractionalStart)<0.01,"combined fractional shrink above")
        var seed:UInt64=0xA57E1234
        func random(_ upper:Int) -> Int { seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Int((seed >> 32) % UInt64(upper)) }
        for count in [12,100,1000] {
            let w=World(count);let index=count/2
            for round in 0..<120 {
                w.anchor(index);let start=w.view.contentOffset.y,oldPrefix=w.heights.prefix(index).reduce(0,+)
                for _ in 0..<10 { let i=random(count);w.heights[i]=CGFloat(40+random(220)) }
                let newPrefix=w.heights.prefix(index).reduce(0,+)
                var order=Array(w.messages.indices)
                for i in order.indices.reversed() { order.swapAt(i,random(i+1)) }
                var tops=Array(repeating:CGFloat(0),count:count);var y:CGFloat=0
                for i in w.heights.indices { tops[i]=y;y+=w.heights[i] }
                for i in order { report(w.v,w.messages[i].id,i,tops[i],w.heights[i],true) }
                check(abs(w.view.contentOffset.y-start-newPrefix+oldPrefix)<0.01,"random order \(count) \(round)")
                w.v.updateViewport(top:w.view.contentOffset.y,height:800);w.v.updateAnchor(messages:w.messages)
                check(w.v.topVisibleIndex(messages:w.messages)==index,"random anchor index")
                check(abs(w.v.consumeCompensation()-newPrefix+oldPrefix)<0.01,"random combined compensation")
                w.refresh();check(w.v.consumeCompensation()==0,"repeat random measurement")
            }
        }
        let removed=World();removed.anchor(50);let removedStart=removed.view.contentOffset.y
        removed.messages.remove(at:20);removed.heights.remove(at:20);removed.refresh()
        _=removed.v.updatedRange(messages:removed.messages,current:nil)
        check(abs(removed.view.contentOffset.y-removedStart+80)<0.01,"remove above")
        removed.v.updateViewport(top:removed.view.contentOffset.y,height:800);removed.v.updateAnchor(messages:removed.messages)
        check(removed.v.topVisibleIndex(messages:removed.messages)==49,"index after removal")
        let reordered=World();reordered.anchor(50);let reorderedStart=reordered.view.contentOffset.y
        let movedMessage=reordered.messages.remove(at:80),movedHeight=reordered.heights.remove(at:80)
        reordered.messages.insert(movedMessage,at:10);reordered.heights.insert(movedHeight,at:10);reordered.refresh()
        _=reordered.v.updatedRange(messages:reordered.messages,current:nil)
        check(abs(reordered.view.contentOffset.y-reorderedStart-80)<0.01,"reorder across anchor")
        reordered.v.updateViewport(top:reordered.view.contentOffset.y,height:800);reordered.v.updateAnchor(messages:reordered.messages)
        reordered.v.updateWidth(700);reordered.change(0,44)
        check(abs(reordered.view.contentOffset.y-reorderedStart-124)<0.01,"resize above")
        verifyRenderGroups(check)
        print("\(checks-failures)/\(checks) virtualizer checks passed")
        if failures>0 { exit(1) }
    }
}
