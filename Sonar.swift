import SwiftUI
import AVFoundation
import ApplicationServices

// Narrowband Hann-windowed DFT; ignores the carrier's central leakage lobe.
struct Spectrum {
 static let window = (0..<4096).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0)/4095) }
 static func powers(_ samples: [Float], rate: Double, carrier: Double) -> [Double] {
  let n = samples.count
  let weighted = samples.enumerated().map { Double($0.element) * window[$0.offset] }
  return stride(from: -300.0, through: 300.0, by: 20).map { offset in
   let coefficient = 2 * cos(2 * Double.pi * (carrier + offset)/rate)
   var previous = 0.0, previous2 = 0.0
   for value in weighted {
    let next = value + coefficient*previous-previous2
    previous2 = previous; previous = next
   }
   return max(0, previous*previous + previous2*previous2-coefficient*previous*previous2)/Double(n*n)
  }
 }
}
// A single pending delivery prevents old motion accumulating behind UI work.
final class LatestSpectrum {
 private let lock = NSLock()
 private var pending: ([Double], Double)?
 private var scheduled = false
 func offer(_ powers: [Double], at time: Double, deliver: @escaping ([Double], Double) -> Void) {
  lock.lock(); pending = (powers, time)
  let needsDelivery = !scheduled; scheduled = true; lock.unlock()
  guard needsDelivery else { return }
  DispatchQueue.main.async {
   self.lock.lock(); let value = self.pending; self.pending = nil; self.scheduled = false; self.lock.unlock()
   if let value = value { deliver(value.0, value.1) }
  }
 }
}
struct MotionGate {
 var active = false
 mutating func update(score: Double, threshold: Double) -> Bool {
  active = score > threshold * (active ? 0.65 : 1)
  return active
 }
}
struct TapDetector {
 var previous = false, began = 0.0, last = -10.0, cooldown = 0.0
 mutating func update(active: Bool, time: Double) -> Bool {
  defer { previous = active }
  if active && !previous { began = time }
  if !active && previous {
   let duration = time-began
   guard duration >= 0.04 && duration <= 0.30 else { last = -10; return false }
   if time-last >= 0.16 && time-last <= 0.70 && time > cooldown {
    last = -10; cooldown = time+1; return true
   }
   last = time
  }
  return false
 }
}
final class Sonar: ObservableObject {
 @Published var running = false
 @Published var status = "Ready when you are"
 @Published var strength = 0.0
 @Published var bars = Array(repeating: 0.0, count: 31)
 @Published var down = true
 @Published var sensitivity = 1.2
 @Published var speed = 30.0
 @Published var frequency = 20000.0
 @Published var systemScroll = false
 @Published var demoPosition = 0.0
 var engine: AVAudioEngine?
 var detector = TapDetector()
 var baseline = Array(repeating: 0.0, count: 31)
 var calibration = 0
 var started = ProcessInfo.processInfo.systemUptime
 var motion = MotionGate()
 var scrollRemainder = 0.0
 var lastTick = 0.0
 var session = UUID()
 var routeObserver: NSObjectProtocol?
 func start() {
  guard !running else { return }
  status = "Requesting microphone…"
  AVCaptureDevice.requestAccess(for: .audio) { ok in
   DispatchQueue.main.async {
    if ok { self.beginAudio() } else { self.status = "Allow microphone access in System Settings, then try again." }
   }
  }
 }
 func beginAudio() {
  guard !running else { return }
  let e = AVAudioEngine()
  let input = e.inputNode
  let format = input.outputFormat(forBus: 0)
  let outRate = e.outputNode.outputFormat(forBus: 0).sampleRate
  guard format.channelCount > 0, format.sampleRate > frequency*2+800, outRate > frequency*2+800 else {
   status = "Use built-in speakers and a microphone at 44.1 or 48 kHz."; return
  }
  let carrier = frequency
  var phase = 0.0
  var ramp = 0.0
  let source = AVAudioSourceNode { _, _, count, list -> OSStatus in
   let buffers = UnsafeMutableAudioBufferListPointer(list)
   for i in 0..<Int(count) {
    ramp = min(1, ramp + 1/(outRate*0.1))
    let value = Float(sin(phase) * 0.025 * ramp)
    phase += 2 * .pi * carrier/outRate
    if phase > 2 * .pi { phase -= 2 * .pi }
    for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[i] = value }
   }
   return noErr
  }
  e.attach(source)
  e.connect(source, to: e.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 1)!)
  let id = UUID(); session = id
  var pending: [Float] = []
  pending.reserveCapacity(8192)
  let mailbox = LatestSpectrum()
  input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
   guard let data = buffer.floatChannelData?[0] else { return }
   pending.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
   while pending.count >= 4096 {
    let p = Spectrum.powers(Array(pending.prefix(4096)), rate: format.sampleRate, carrier: carrier)
    pending.removeFirst(512)
    let capturedAt = ProcessInfo.processInfo.systemUptime
    mailbox.offer(p, at: capturedAt) { [weak self] powers, time in
     guard let self = self, self.session == id, self.running else { return }
     self.consume(powers, at: time)
    }
   }
  }
  do {
   try e.start(); engine = e; running = true; recalibrate()
   routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
    self?.stop(); self?.status = "Audio device changed. Start again to recalibrate."
   }
  } catch {
   input.removeTap(onBus: 0); e.stop(); status = "Could not start audio: \(error.localizedDescription)"
  }
 }
 func recalibrate() { calibration = 0; baseline = Array(repeating: 0, count: 31); detector = TapDetector(); started = ProcessInfo.processInfo.systemUptime; motion = MotionGate(); lastTick = 0; scrollRemainder = 0; strength = 0; status = "Calibrating · keep your hands still for 3 seconds" }
 func consume(_ p: [Double], at time: Double) {
  guard time >= started, ProcessInfo.processInfo.systemUptime-time < 0.12 else { return }
  bars = p.map { min(1, max(0, (10*log10(max($0, 1e-12))+100)/70)) }
  let t = time-started
  if t < 3 {
   calibration += 1
   for i in p.indices { baseline[i] += (p[i]-baseline[i])/Double(calibration) }
   return
  }
  let carrierPower = p[15]
  guard carrierPower > 1e-9 else { strength = 0; motion = MotionGate(); detector = TapDetector(); status = "Carrier too weak · use built-in speakers and raise volume slightly"; return }
  var excess = 0.0, noise = 0.0
  for i in p.indices where abs(i-15) >= 4 {
   excess += max(0, p[i]-baseline[i]); noise += baseline[i]
  }
  let score = excess / max(noise, carrierPower*0.0002, 1e-10)
  strength = min(1, score/(sensitivity*2))
  let active = motion.update(score: score, threshold: sensitivity)
  if detector.update(active: active, time: t) { down.toggle(); status = "Double tap · direction reversed"; lastTick = t; return }
  status = active ? "Motion detected" : "Listening for hand motion"
  if !active { for i in p.indices { baseline[i] = baseline[i]*0.9996+p[i]*0.0004 } }
  // Faster onset trades a small amount of tap-associated scrolling for responsiveness.
  if !active { lastTick = t; scrollRemainder = 0 }
  if active && t-detector.began > 0.08 && t-lastTick >= 0.016 {
   let elapsed = min(0.04, t-lastTick)
   lastTick = t
   scrollRemainder += speed * min(2, score/sensitivity) * elapsed/0.085
   let wholePixels = Int32(scrollRemainder)
   scrollRemainder -= Double(wholePixels)
   let pixels = wholePixels * (down ? -1 : 1)
   demoPosition = min(1000, max(0, demoPosition-Double(pixels)))
   if systemScroll {
    guard AXIsProcessTrusted() else { systemScroll = false; status = "Enable Accessibility to scroll other apps"; return }
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
   }
  }
 }
 func stop() {
  session = UUID(); running = false
  if let observer = routeObserver { NotificationCenter.default.removeObserver(observer); routeObserver = nil }
  engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil; strength = 0; status = "Paused · sound and microphone off"
 }
 func enableScrolling() {
  if AXIsProcessTrusted() { systemScroll = true }
  else {
   _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
   status = "Allow Sonar in System Settings → Privacy & Security → Accessibility, then enable again."
  }
 }
}

struct ContentView: View {
 @ObservedObject var model: Sonar
 let mint = Color(red: 0.46, green: 0.98, blue: 0.76)
 var body: some View {
  VStack(alignment: .leading, spacing: 26) {
   HStack {
    Image(nsImage: NSImage(named: "SonarIcon") ?? NSImage()).resizable().scaledToFit().frame(width: 44, height: 44)
    Text("sonar").font(.system(size: 30, weight: .semibold, design: .rounded))
    Spacer()
    Text("TOUCHLESS SCROLL").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
    Circle().fill(model.running ? mint : .gray).frame(width: 8, height: 8)
   }
   HStack(alignment: .top, spacing: 30) {
    VStack(spacing: 20) {
     ZStack {
      ForEach(0..<4) { i in Circle().stroke(mint.opacity(0.12+Double(i)*0.04), lineWidth: 1).frame(width: CGFloat(110+i*46), height: CGFloat(110+i*46)) }
      Circle().fill(mint.opacity(0.08+model.strength*0.22)).frame(width: 108, height: 108)
      Image(systemName: model.down ? "arrow.down" : "arrow.up").font(.system(size: 42, weight: .light)).foregroundStyle(mint)
     }.frame(width: 290, height: 265)
     Text(model.down ? "Scrolling down" : "Scrolling up").font(.title2)
     Button("Reverse direction  ↕") { model.down.toggle() }.buttonStyle(.bordered)
     HStack(alignment: .bottom, spacing: 3) {
      ForEach(0..<31) { i in RoundedRectangle(cornerRadius: 2).fill(mint.opacity(i == 15 ? 1 : 0.5)).frame(width: 5, height: 4+model.bars[i]*48) }
     }.frame(height: 55)
     VStack(alignment: .leading, spacing: 6) {
      Text("SCROLL TEST").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
      ProgressView(value: model.demoPosition, total: 1000).tint(mint)
      Text("\(Int(model.demoPosition)) / 1000 px").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
     }.frame(width: 235)
     Text("LIVE ECHO · \(Int(model.frequency)) Hz").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
    }
    VStack(alignment: .leading, spacing: 22) {
     Text("A little motion.\nA new way to scroll.").font(.system(size: 29, weight: .medium)).fixedSize(horizontal: false, vertical: true)
     Text("Move a hand toward or away from your Mac to scroll. Make two short air taps to reverse direction. Quick taps may also scroll slightly.").foregroundStyle(.secondary).lineSpacing(4)
     Divider()
     HStack { Text("Sensitivity"); Spacer(); Text(String(format: "%.1f", 6.4-model.sensitivity)).foregroundStyle(mint) }
     Slider(value: $model.sensitivity, in: 0.4...6).environment(\.layoutDirection, .rightToLeft).tint(mint).accessibilityLabel("Detection threshold, lower is more sensitive")
     HStack { Text("Scroll speed"); Spacer(); Text("\(Int(model.speed))").foregroundStyle(mint) }
     Slider(value: $model.speed, in: 3...90).tint(mint)
     Picker("Carrier", selection: $model.frequency) { Text("19 kHz").tag(19000.0); Text("20 kHz").tag(20000.0); Text("21 kHz").tag(21000.0) }.disabled(model.running)
     Toggle("Scroll other apps", isOn: Binding(get: { model.systemScroll }, set: { if $0 { model.enableScrolling() } else { model.systemScroll = false } })).tint(mint)
     Text("Requires Accessibility access. Place your pointer over the window you want to scroll.").font(.system(size: 13)).foregroundStyle(.secondary)
    }.frame(width: 310)
   }
   VStack(alignment: .leading, spacing: 10) {
    HStack { Text("MOTION").font(.system(size: 12, design: .monospaced)); Spacer(); Text(model.status).font(.system(size: 13)).foregroundStyle(.secondary) }
    ProgressView(value: model.strength).tint(mint)
    HStack {
     Button(model.running ? "Stop sonar" : "Start sonar") { model.running ? model.stop() : model.start() }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black).controlSize(.large)
     Button("Recalibrate") { model.recalibrate() }.disabled(!model.running)
     Spacer()
     Text("⌘ . to stop").font(.system(size: 13)).foregroundStyle(.secondary)
    }
   }
   Text("Use built-in speakers and microphone at low volume. High-frequency audio may be audible to some people or animals. Motion sensing is experimental; a still hand does not provide distance. Audio is processed locally and never saved.").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }.padding(32).frame(width: 720).background(Color(red: 0.045, green: 0.075, blue: 0.09)).preferredColorScheme(.dark)
 }
}
@main struct SonarApp: App {
 @StateObject var model = Sonar()
 var body: some Scene {
  WindowGroup { ContentView(model: model).onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() } }.windowResizability(.contentSize)
   .commands { CommandMenu("Sonar") { Button("Stop sonar") { model.stop() }.keyboardShortcut(".", modifiers: .command) } }
  MenuBarExtra("Sonar", systemImage: "wave.3.right") {
   Text(model.status)
   Button(model.running ? "Stop sonar" : "Start sonar") { model.running ? model.stop() : model.start() }
   Button("Reverse direction") { model.down.toggle() }
   Button("Quit") { model.stop(); NSApplication.shared.terminate(nil) }
  }
 }
}
