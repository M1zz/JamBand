import SwiftUI

struct PlayingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let _ = context.date
            let now = Clock.now()
            let start = state.startTime ?? now
            let beat = (now - start) * state.song.bpm / 60.0
            let color = state.myInstrument?.color ?? .accentColor

            VStack(spacing: 32) {
                Spacer()

                Text(state.myInstrument?.emoji ?? "🎵")
                    .font(.system(size: 96))

                Text(state.myInstrument?.name ?? "")
                    .font(.title2.bold())

                ZStack {
                    Circle()
                        .fill(color.opacity(0.25))
                        .frame(width: 220, height: 220)
                        .scaleEffect(beat < 0 ? 1 : 1 + 0.25 * max(0, 1 - (beat - floor(beat)) * 3))

                    if beat < 0 {
                        Text("\(Int(ceil(-beat * 60.0 / state.song.bpm)))")
                            .font(.system(size: 80, weight: .heavy, design: .rounded))
                    } else {
                        let bar = Int(beat) / state.song.beatsPerBar % state.song.bars + 1
                        let beatInBar = Int(beat) % state.song.beatsPerBar + 1
                        VStack {
                            Text("\(bar)")
                                .font(.system(size: 64, weight: .heavy, design: .rounded))
                            Text("beat \(beatInBar)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(beat < 0 ? "곧 시작합니다…"
                     : state.demoMode ? "데모 · 가상 밴드 \(state.demoPeers.count)명과 합주 중 · \(Int(state.song.bpm)) BPM"
                     : "\(state.participantCount)명 합주 중 · \(Int(state.song.bpm)) BPM")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    state.stopPlayback(broadcast: true)
                } label: {
                    Label("정지", systemImage: "stop.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .animation(.easeOut(duration: 0.08), value: beat < 0)
        }
    }
}
