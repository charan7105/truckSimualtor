import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so logs appear live when piped

// `swift run MatrackTruckSim selftest` → run the 10-cycle headless validation (no Bluetooth).
if CommandLine.arguments.contains("selftest") {
    exit(SelfTest.run())
}

// `swift run MatrackTruckSim capture` → connect to a REAL MT tracker (Mac as central) and log raw packets.
if CommandLine.arguments.contains("capture") {
    let cap = MTCapture()
    cap.start()
    RunLoop.main.run()
}

MatrackSimApp.main()
