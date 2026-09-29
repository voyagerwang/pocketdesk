import Foundation
@main struct Tests {
 static func main() {
    func check(_ ok: Bool,_ name: String) { precondition(ok,name); print("PASS " + name) }
    check(HeadsetNanoseconds(10831369528706,numer:125,denom:3) == 451307063696083,"recorded headset and native Option timestamps match")
    check(HeadsetNanoseconds(10831445943073,numer:125,denom:3) == 451310247628041,"recorded release timestamps match")
    var classifier = HeadsetButtonClassifier()
    let trace: [(Bool,UInt64)] = [(true,451314215724416),(false,451314455574541),(true,451314567583291),(false,451314759574208)]
    let doubles = trace.compactMap { classifier.edge(down:$0.0,time:$0.1) }.filter { $0.second && !$0.down }
    check(doubles.count == 1,"recorded headset double-click produces exactly one send request")
    var held = HeadsetButtonClassifier()
    _ = held.edge(down:true,time:1_000_000_000)
    check(held.edge(down:true,time:1_100_000_000) == nil,"held repeats do not count as clicks")
    _ = held.edge(down:false,time:4_000_000_000)
    check(!held.edge(down:true,time:4_200_000_000)!.second,"next press after dictation hold is not a double-click")
    func gate(focus:Bool=true,seen:Bool=true,visible:Bool=false,changed:Bool=true,nonempty:Bool=true,stable:Double=2,closed:Double=2) -> Bool {
      HeadsetSendGate.ready(sameFocus:focus,panelObserved:seen,panelVisible:visible,textChanged:changed,nonempty:nonempty,stableFor:stable,closedFor:closed,delay:2)
    }
    check(!gate(visible:true,stable:10,closed:10),"pause while speaking cannot send")
    check(!gate(seen:false),"unobserved recording cannot send")
    check(!gate(focus:false),"focus change prevents sending")
    check(!gate(changed:false),"unchanged prior draft cannot auto-send")
    check(!gate(nonempty:false),"empty transcription cannot send")
    check(!gate(stable:1.9),"late transcription update restarts delay")
    check(!gate(closed:1.9),"voice panel closure starts delay")
    check(gate(),"finished transcription sends after full two seconds")
 }
}
