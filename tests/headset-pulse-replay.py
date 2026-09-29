from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / "Sources/HeadsetLongPress.swift").read_text().replace("private ", "")
a = s.index("    func lowerVolumeOnce() {")
b = s.index("    func receive(down:", a)
s = s[:a] + "    var volumeCount = 0\n    func lowerVolumeOnce() { volumeCount += 1 }\n" + s[b:]
s += '\nenum LockScreenInput { static let locked = false }\nfinal class HeadsetPairing { static let shared = HeadsetPairing(); let isActive = false }\n@main struct ReplayTests {\n static func main() {\n  func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }\n  let pulse = HeadsetLongPress(); pulse.pulseMode = true\n  var begins = 0; var ends = 0\n  pulse.onBegin = { begins += 1 }; pulse.onEnd = { ends += 1 }\n  // Reproduce the observed AB13X pulse spacing without posting any real key events.\n  for _ in 0..<8 { pulse.receive(down: true); pulse.receive(down: false); wait(0.174) }\n  wait(0.35)\n  precondition(begins == 1 && ends == 1 && pulse.volumeCount == 0)\n  let short = HeadsetLongPress(); short.pulseMode = true\n  short.receive(down: true); short.receive(down: false); wait(0.35)\n  precondition(short.volumeCount == 1)\n  let cancel = HeadsetLongPress(); cancel.pulseMode = true\n  cancel.receive(down: true); cancel.receive(down: false); cancel.cancel(); wait(0.8)\n  precondition(cancel.volumeCount == 0)\n  let native = HeadsetLongPress(); var nativeBegin = 0; var nativeEnd = 0\n  native.onBegin = { nativeBegin += 1 }; native.onEnd = { nativeEnd += 1 }\n  native.receive(down: true); wait(0.75); native.receive(down: false)\n  precondition(nativeBegin == 1 && nativeEnd == 1 && native.volumeCount == 0)\n  print("PASS AB13X pulse trace: one begin/end, zero volume; short click; cancellation; native hold")\n }\n}\n'
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "PulseReplay.swift"
    source.write_text(s)
    exe = Path(directory) / "pulse-replay"
    subprocess.run(["swiftc", str(root / "Sources/HeadsetProfiles.swift"), str(source), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
