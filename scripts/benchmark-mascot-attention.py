#!/usr/bin/env python3
"""Compare the installed-baseline and candidate motion sources, without GUI input."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--baseline-source", type=Path, required=True)
args = parser.parse_args()
root = args.root.resolve()
assert str(root).startswith("/private/tmp/clipslots-editor-")
root.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parent.parent
old = args.baseline_source.read_text().split("public enum MascotResources")[0]
new = (repo / "Sources/ClipSlotsKit/MascotMotion.swift").read_text().split("public enum MascotResources")[0]
for name in ["MascotPose", "MascotScheduleHint", "MascotMotion"]:
    old = old.replace(name, "Legacy" + name)
(root / "Legacy.swift").write_text(old)
(root / "Current.swift").write_text(new)
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
func cost<T:Motion>(_ type:T.Type)->Double {
    let engine=T(), start=ProcessInfo.processInfo.systemUptime
    for i in 0..<100000 {
        let time=Double(i)*1000/60
        if i%3==0 { engine.setPointer(x:Double((i/60)%2==0 ? 220 : -220),y:60,at:time) }
        checksum+=engine.advance(time)
    }
    return (ProcessInfo.processInfo.systemUptime-start)*1e9/100000
}
func trace<T:Motion>(_ type:T.Type,_ scenario:String)->[[Double]] {
    let engine=T();_=engine.advance(0)
    var rows:[[Double]]=[]
    for i in 0...600 {
        let time=Double(i)*1000/60
        if scenario=="step" && i==0 { engine.setPointer(x:10000,y:0,at:time) }
        if scenario=="reverse" && i==0 { engine.setPointer(x:220,y:60,at:time) }
        if scenario=="reverse" && i==36 { engine.setPointer(x:-220,y:-60,at:time) }
        if scenario=="jitter" && i%3==0 {
            engine.setPointer(x:150+Double((i/3)%3-1),y:30,at:time)
        }
        rows.append([time,engine.advance(time),engine.active ? 1 : 0])
    }
    return rows
}
func metrics(_ rows:[[Double]])->[String:Double] {
    var speed=0.0,accel=0.0,lastSpeed=0.0,lastMotion=0.0
    for i in 1..<rows.count {
        let v=(rows[i][1]-rows[i-1][1])*60
        speed=max(speed,abs(v));accel=max(accel,abs(v-lastSpeed)*60);lastSpeed=v
        if abs(v)>0.000001 { lastMotion=rows[i][0] }
    }
    return ["yaw_at_100ms":rows[6][1],"peak_speed_deg_s":speed,"peak_acceleration_deg_s2":accel,
        "active_pose_frames":rows.reduce(0){$0+$1[2]},
        "last_motion_ms":lastMotion]
}
var oldCosts:[Double]=[],newCosts:[Double]=[]
for i in 0..<5 {
    if i%2==0 { oldCosts.append(cost(LegacyMascotMotion.self));newCosts.append(cost(MascotMotion.self)) }
    else { newCosts.append(cost(MascotMotion.self));oldCosts.append(cost(LegacyMascotMotion.self)) }
}
var before:[String:[String:Double]]=[:],after:[String:[String:Double]]=[:]
var traces:[String:[[Double]]]=[:]
for name in ["step","reverse","jitter"] {
    let a=trace(LegacyMascotMotion.self,name),b=trace(MascotMotion.self,name)
    before[name]=metrics(a);after[name]=metrics(b)
    traces[name]=b
}
let checks=[
    "response_by_100ms_without_snap":after["step"]!["yaw_at_100ms"]! > 0 && after["step"]!["yaw_at_100ms"]! < 15,
    "turn_speed_bounded":after["step"]!["peak_speed_deg_s"]! <= 151,
    "reversal_acceleration_bounded":after["reverse"]!["peak_acceleration_deg_s2"]! < 8000,
    "jitter_render_frames_stay_bounded":after["jitter"]!["active_pose_frames"]! < 100,
    "step_releases_render_cadence":after["step"]!["last_motion_ms"]! < 1100,
    "integration_cpu_below_10_microseconds":newCosts.sorted()[2] < 10000
]
let report:[String:Any]=["scope":"Actual installed-baseline/candidate motion sources; 60Hz model traces, not physical display scanout. Near/far event admission and renderer CPU are measured separately.",
    "baseline_ns_per_sample":oldCosts,"candidate_ns_per_sample":newCosts,
    "baseline":before,"candidate":after,"traces":traces,"checks":checks,
    "passed":checks.values.allSatisfy{$0},"checksum":checksum]
print(String(data:try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
''')
subprocess.run(["swiftc", "-Onone", str(root / "Legacy.swift"), str(root / "Current.swift"),
                str(root / "main.swift"), "-o", str(root / "benchmark")], check=True)
raw = subprocess.check_output([str(root / "benchmark")], text=True)
(root / "motion.json").write_text(raw)
report = json.loads(raw)
print(json.dumps({k: v for k, v in report.items() if k != "traces"}, indent=2))
raise SystemExit(0 if report["passed"] else 1)
