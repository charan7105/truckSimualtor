import SwiftUI

/// Cinematic ignition overlay shown until `sim.phase == .live`.
/// Cold → a breathing START button; press → power-on sweep + count-up → "SYSTEMS NOMINAL" → reveal.
struct IgnitionView: View {
    @EnvironmentObject var sim: SimController
    @State private var breathe = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.bg0)
            RadialGradient(colors: [Theme.ice.opacity(0.06), .clear], center: .center, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.red.opacity(sim.phase == .cold ? 0.10 : 0.17), .clear],
                           center: .center, startRadius: 0, endRadius: 640)

            if sim.phase == .cold {
                startButton
                // low-opacity descriptor, top-middle ("what is this")
                VStack(spacing: 10) {
                    Text("VIRTUAL TRUCK · J1939 / MT TRACKER")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(4)
                        .foregroundStyle(Theme.ice.opacity(0.45))
                    Text("MATRACK TRUCK SIMULATOR")
                        .font(.system(size: 17, weight: .heavy, design: .rounded)).tracking(5)
                        .foregroundStyle(Theme.text.opacity(0.45))
                    Text("Streams a real truck's engine, GPS, and diagnostics to the Matrack ELD app\nover Bluetooth — no hardware required.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).tracking(0.5)
                        .foregroundStyle(Theme.dim.opacity(0.6))
                        .lineSpacing(3)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 56)
            } else {
                sweepStage
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { if sim.phase != .cold { sim.skipStartup() } }
    }

    private var startButton: some View {
        VStack(spacing: 24) {
            Button { sim.beginStartup() } label: {
                ZStack {
                    Circle().stroke(Theme.red.opacity(0.4), lineWidth: 2).frame(width: 156, height: 156)
                    Circle().fill(Theme.red.opacity(0.10)).frame(width: 132, height: 132)
                    Circle().stroke(Theme.red, lineWidth: 3).frame(width: 132, height: 132)
                        .shadow(color: Theme.red.opacity(0.8), radius: breathe ? 26 : 10)
                    VStack(spacing: 6) {
                        Image(systemName: "power").font(.system(size: 40, weight: .bold)).foregroundStyle(Theme.red)
                        Text("START").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(4).foregroundStyle(Theme.text)
                    }
                }
                .scaleEffect(breathe ? 1.04 : 1.0)
            }
            .buttonStyle(.plain)
            Text("PRESS TO INITIALIZE")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).tracking(2.5).foregroundStyle(Theme.dim)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true } }
    }

    private var sweepStage: some View {
        let target: Double = sim.phase == .sweep ? 1.0 : (sim.phase == .settle ? 0.12 : 0.0)
        return VStack(spacing: 34) {
            HStack(spacing: 90) {
                SweepDial(frac: target, arc: Theme.speedArc, big: "\(Int(target * 150))", unit: "KM/H")
                SweepDial(frac: target, arc: Theme.tachArc, big: "\(Int(target * 3000))", unit: "RPM")
            }
            .animation(.easeOut(duration: sim.phase == .sweep ? 0.7 : 0.5), value: sim.phase)

            Text("SYSTEMS NOMINAL")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).tracking(4)
                .foregroundStyle(Theme.green)
                .opacity(sim.phase == .settle ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: sim.phase)
        }
    }
}

private struct SweepDial: View {
    var frac: Double
    var arc: [Color]
    var big: String
    var unit: String
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.06), style: .init(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * max(0, min(1, frac)))
                .stroke(AngularGradient(gradient: Gradient(colors: arc), center: .center,
                                        startAngle: .degrees(135), endAngle: .degrees(405)),
                        style: .init(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
                .glow(arc.first ?? Theme.ice, 12)
            VStack(spacing: 2) {
                Text(big).font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text).contentTransition(.numericText())
                Text(unit).font(.system(size: 12, weight: .bold, design: .rounded)).tracking(5).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 240, height: 240)
    }
}
