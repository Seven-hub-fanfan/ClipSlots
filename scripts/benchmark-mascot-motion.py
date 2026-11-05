#!/usr/bin/env python3
"""Compile the actual old/new motion sources and compare CPU and settling."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, required=True)
args = parser.parse_args()
root = args.root.resolve()
assert str(root).startswith("/private/tmp/clipslots-editor-")
root.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parent.parent
relative = "Sources/ClipSlotsKit/MascotMotion.swift"
baseline = subprocess.check_output(["git", "show", "HEAD:" + relative], cwd=repo, text=True)
candidate = (repo / relative).read_text()
# Resource lookup is unrelated to integration and requires the app's Kit bundle.
baseline = baseline.split("public enum MascotResources")[0]
candidate = candidate.split("public enum MascotResources")[0]
for name in ["MascotPose", "MascotScheduleHint", "MascotMotion"]:
    baseline = baseline.replace(name, "Legacy" + name)
(root / "Legacy.swift").write_text(baseline)
(root / "Current.swift").write_text(candidate)
(root / "main.swift").write_text(r'''
import Foundation
protocol Motion {
    init()
    func setPointer(x:Double?,y:Double?,at:Double)
    func advance(_ time:Double)->Double
    var active:Bool { get }
}
extension LegacyMascotMotion:Motion {
    func advance(_ time:Double)->Double { sample(at:time).yaw }
    var active:Bool { highFrameRate }
}
extension MascotMotion:Motion {
    func advance(_ time:Double)->Double { sample(at:time).yaw }
    var active:Bool { highFrameRate }
}
var checksum=0.0
func work<T:Motion>(_ type:T.Type,_ count:Int)->Double {
    let engine=T()
    let start=ProcessInfo.processInfo.systemUptime
    for i in 0..<count {
        let time=Double(i)*1000/60
        if i%12==0 { engine.setPointer(x:Double((i/12)%2==0 ? 800 : -800),y:100,at:time) }
        checksum+=engine.advance(time)
        if engine.active { checksum+=0.000001 }
    }
    return (ProcessInfo.processInfo.systemUptime-start)*1e9/Double(count)
}
func metrics<T:Motion>(_ type:T.Type)->[String:Double] {
    let engine=T();_=engine.advance(0);engine.setPointer(x:10000,y:0,at:0)
    var settle=0.0, response=0.0, frames=0
    for i in 1...90 {
        let time=Double(i)*1000/60, yaw=engine.advance(time)
        if i==6 { response=yaw }
        if !engine.active { settle=time;frames=i;break }
    }
    let reverse=T();_=reverse.advance(0);reverse.setPointer(x:10000,y:0,at:0)
    let a=reverse.advance(79),b=reverse.advance(80)
    reverse.setPointer(x:-10000,y:0,at:80)
    let c=reverse.advance(81)
    return ["settle_ms":settle,"active_frames":Double(frames),"yaw_at_100ms":response,
            "reversal_velocity_change_deg_per_second":abs((c-b)-(b-a))*1000]
}
_=work(LegacyMascotMotion.self,10000);_=work(MascotMotion.self,10000)
var old:[Double]=[],new:[Double]=[]
for i in 0..<5 {
    if i%2==0 { old.append(work(LegacyMascotMotion.self,100000));new.append(work(MascotMotion.self,100000)) }
    else { new.append(work(MascotMotion.self,100000));old.append(work(LegacyMascotMotion.self,100000)) }
}
let oldMedian=old.sorted()[2],newMedian=new.sorted()[2]
let before=metrics(LegacyMascotMotion.self),after=metrics(MascotMotion.self)
let checks=["cpu_within_10_percent":newMedian<=oldMedian*1.1,
            "shorter_active_render_tail":after["active_frames"]!<before["active_frames"]!,
            "reversal_velocity_jump_reduced_by_90_percent":
                after["reversal_velocity_change_deg_per_second"]!<before["reversal_velocity_change_deg_per_second"]!*0.1,
            "100ms_response_preserved":after["yaw_at_100ms"]!>=before["yaw_at_100ms"]!]
let report:[String:Any]=["scope":"Actual old/new source, same non-optimized Swift settings as local app; five alternating 100000-sample trials.",
    "baseline_ns_per_sample":old,"candidate_ns_per_sample":new,
    "baseline_median_ns":oldMedian,"candidate_median_ns":newMedian,"cpu_ratio":newMedian/oldMedian,
    "baseline_motion":before,"candidate_motion":after,"checks":checks,
    "passed":checks.values.allSatisfy{$0},"checksum":checksum]
let data=try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
''')
subprocess.run(["swiftc", "-Onone", str(root / "Legacy.swift"), str(root / "Current.swift"),
                str(root / "main.swift"), "-o", str(root / "motion-benchmark")], check=True)
raw = subprocess.check_output([str(root / "motion-benchmark")], text=True)
(root / "motion-benchmark.json").write_text(raw)
report = json.loads(raw)
print(raw)
raise SystemExit(0 if report["passed"] else 1)
