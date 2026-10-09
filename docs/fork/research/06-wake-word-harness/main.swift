// Wake-word spike harness. Build + run steps are in docs/fork/research/06-wake-word-spike.md.
// Prints a timestamped line per trigger plus a running count, so you can compute
// detection rate and false accepts per hour. Run as a terminal command; it is NOT the app.
import Foundation

let detector = WakeWordDetector()
let startDate = Date()
var triggerCount = 0
detector.onWakeWordDiagnosticLog = { message in
    triggerCount += 1
    let elapsed = Int(Date().timeIntervalSince(startDate))
    print("[+\(elapsed)s] #\(triggerCount) \(message)")
    fflush(stdout)
}
detector.startListening()
print("Listening for 'Hey Clicky'. Ctrl-C to stop.")
fflush(stdout)
RunLoop.main.run()
