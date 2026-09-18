import SwiftUI

struct LobbyView: View {
    @Environment(AppState.self) private var state

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusCard
                    instrumentGrid
                    playerList
                    readyButton
                    Text("모든 플레이어가 준비되면 3초 후 자동으로 시작됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("JamBand")
        }
    }

    // MARK: - Sections

    private var statusCard: some View {
        HStack {
            Label("\(state.participantCount)명 접속", systemImage: "person.2.fill")
            Spacer()
            if state.isLeader {
                Label("리더", systemImage: "crown.fill")
                    .foregroundStyle(.yellow)
            } else if state.clockSynced {
                Label("동기화 \(Int(state.lastRTT * 1000))ms", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("시계 동기화 중…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private var instrumentGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("악기 선택")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(state.instruments) { instrument in
                    InstrumentCard(
                        instrument: instrument,
                        selected: state.me.instrument == instrument.id,
                        owners: state.owners(of: instrument.id)
                    )
                    .onTapGesture { state.selectInstrument(instrument.id) }
                }
            }
        }
    }

    private var playerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("플레이어")
                .font(.headline)
            ForEach(state.participants) { peer in
                HStack {
                    Text(state.displayName(for: peer))
                        .lineLimit(1)
                    if peer.name == state.leaderName {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                    Spacer()
                    Text(state.instrument(for: peer.instrument)?.emoji ?? "—")
                    Image(systemName: peer.ready ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(peer.ready ? .green : .secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private var readyButton: some View {
        VStack(spacing: 8) {
            Button {
                state.toggleReady()
            } label: {
                Text(state.me.ready ? "준비 취소" : "준비 완료")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.me.ready ? .gray : .green)
            .disabled(!state.canReady)

            if let error = state.audioError {
                Text("오디오 오류: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if state.me.instrument == nil {
                Text("먼저 악기를 선택하세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Instrument card

struct InstrumentCard: View {
    let instrument: Instrument
    let selected: Bool
    let owners: [String]

    var body: some View {
        VStack(spacing: 6) {
            Text(instrument.emoji)
                .font(.system(size: 40))
            Text(instrument.name)
                .font(.headline)
            Text(owners.isEmpty ? "비어 있음" : owners.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(instrument.color.opacity(selected ? 0.35 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? instrument.color : .clear, lineWidth: 3)
        )
        .contentShape(Rectangle())
    }
}
