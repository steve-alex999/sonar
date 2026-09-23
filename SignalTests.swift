let rate = 48000.0
let tone = (0..<4096).map { Float(sin(2 * Double.pi * 20140 * Double($0)/rate)) }
let p = Spectrum.powers(tone, rate: rate, carrier: 20000)
assert(p.enumerated().max(by: { $0.element < $1.element })!.offset == 22, "Doppler peak")
assert(Spectrum.powers(Array(repeating: 0, count: 4096), rate: rate, carrier: 20000).allSatisfy { $0 == 0 })
var d = TapDetector()
assert(!d.update(active: true, time: 1))
assert(!d.update(active: false, time: 1.12))
assert(!d.update(active: true, time: 1.3))
assert(d.update(active: false, time: 1.43))
assert(!d.update(active: true, time: 1.5))
assert(!d.update(active: false, time: 1.6))
var slow = TapDetector()
assert(!slow.update(active: true, time: 1))
assert(!slow.update(active: false, time: 2))
assert(!slow.update(active: true, time: 2.1))
assert(!slow.update(active: false, time: 2.2))
print("PASS: frequency-shift detection, silence, double tap, cooldown, sustained-motion rejection")

var gate = MotionGate()
assert(gate.update(score: 1.3, threshold: 1.2))
assert(gate.update(score: 1.0, threshold: 1.2))
assert(!gate.update(score: 0.7, threshold: 1.2))
assert(!gate.update(score: 1.0, threshold: 1.2))
let carrier = (0..<4096).map { Float(0.1*sin(2 * Double.pi * 20000 * Double($0)/rate)) }
let reflection = (0..<4096).map { carrier[$0] + Float(0.002*sin(2 * Double.pi * 20140 * Double($0)/rate)) }
let baseline = Spectrum.powers(carrier, rate: rate, carrier: 20000)
let reflected = Spectrum.powers(reflection, rate: rate, carrier: 20000)
assert(reflected[22] > baseline[22]*100, "Weak reflection remains detectable beside carrier")
for index in [0, 15, 22, 30] {
 let f = 20000 + Double(index-15)*20
 var re = 0.0, im = 0.0
 for i in 0..<4096 {
  let phase = 2*Double.pi*f*Double(i)/rate
  let v = Double(reflection[i])*Spectrum.window[i]
  re += v*cos(phase); im += v*sin(phase)
 }
 let expected = (re*re+im*im)/Double(4096*4096)
 assert(abs(reflected[index]-expected) < max(1e-14, expected*1e-6), "Goertzel matches reference DFT")
}
let start = ProcessInfo.processInfo.systemUptime
for _ in 0..<100 { _ = Spectrum.powers(reflection, rate: rate, carrier: 20000) }
let ms = (ProcessInfo.processInfo.systemUptime-start)*10
print("PASS: hysteresis, weak reflection, reference DFT agreement")
print("Analysis average: \(ms) ms; hop budget at 48 kHz: 10.67 ms")
// Timing is informational because build mode and hardware affect performance.
