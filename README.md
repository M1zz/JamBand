# JamBand — 근접 연결 합주 데모 (iOS)

여러 대의 iPhone이 Wi-Fi/Bluetooth로 자동 연결되고, 각자 악기를 고른 뒤 "준비 완료"를 누르면
3초 카운트다운 후 **모든 기기가 같은 곡의 자기 파트를 동시에** 연주합니다.
서버 없음, 외부 라이브러리 없음, 음원 파일 없음 — 모든 소리는 앱 안에서 합성됩니다.

## 실행

1. `JamBand.xcodeproj`를 Xcode 15 이상에서 엽니다.
2. `JamBand` 타깃 → Signing & Capabilities에서 **Team**을 선택합니다.
   (Bundle ID `com.devkoan.jamband`는 원하는 값으로 바꿔도 됩니다.)
3. 실기기 2대 이상에 설치합니다. 시뮬레이터는 MultipeerConnectivity가 불안정하니 실기기를 권장합니다.
4. 첫 실행 시 뜨는 **로컬 네트워크 허용** 팝업을 승인하세요. 거부하면 기기끼리 서로를 못 찾습니다.
5. 같은 Wi-Fi에 있거나 Bluetooth가 켜져 있으면 몇 초 안에 로비의 접속 인원이 늘어납니다.
6. 각자 악기를 고르고(탭하면 미리듣기), "준비 완료"를 누르면 전원이 준비되는 순간 자동으로 시작됩니다.
7. 혼자서도 됩니다 — 1대에서 악기 선택 → 준비 완료 → 시작.

## 구조

```
JamBand/
├── JamBandApp.swift          앱 진입점
├── ContentView.swift         phase에 따라 로비/연주 화면 전환
├── AppState.swift            로비 상태, 리더 선출, 시계 동기화, 자동 시작
├── Models.swift              Instrument, PeerState, NetMessage
├── Clock.swift               호스트 클럭(초) — 오디오와 네트워크가 같은 시계를 씀
├── Song.swift                곡 데이터 모델 + 내장 데모 곡(6파트, 8마디 루프)
├── Audio/
│   ├── SynthEngine.swift     AVAudioEngine + 렌더 콜백 안의 샘플 정확 시퀀서
│   └── Voice.swift           오실레이터/ADSR/필터 + 합성 드럼
├── Network/
│   └── SessionManager.swift  MultipeerConnectivity 자동 탐색/연결/메시지
└── Views/
    ├── LobbyView.swift       악기 선택, 플레이어 목록, 준비 버튼
    └── PlayingView.swift     카운트다운, 마디/박 표시, 정지
```

### 동기화가 되는 원리

1. **리더 선출** — 접속한 peer 이름 중 사전순으로 가장 작은 기기가 리더. 협상 없이 모두 같은 답을 계산합니다.
2. **시계 동기화** — 팔로워가 1초마다 리더에게 ping을 보내고, NTP 방식으로
   `offset = t1 - (t0 + t2) / 2`를 구합니다. RTT가 가장 짧은 샘플의 offset을 채택합니다.
3. **시작 예약** — 전원이 준비되면 리더가 자기 시계로 `now + 3초`를 브로드캐스트합니다.
   팔로워는 `leaderTime - offset`으로 자기 시계 시각을 얻어 신스에 넘깁니다.
4. **샘플 정확 재생** — 렌더 콜백에서 버퍼의 `mHostTime + outputLatency`를 박 위치로 바꿔,
   그 버퍼 안에 떨어지는 노트를 정확한 샘플 오프셋에서 발음합니다. 시작 이후엔 네트워크 트래픽이 없어도
   각 기기의 오디오 클럭만으로 박자가 유지됩니다.
5. **중간 참여** — 연주 중에 새 기기가 붙으면 리더가 원래 시작 시각을 보내주므로 바로 합류합니다.

## 바꿔보기

- **곡 교체**: `Song.demo()`의 코드 진행(`roots`, `chords`)과 `leadData`를 편집하거나, MIDI 파일을 파싱해서 `[Note]`를 만드는 로더를 추가하세요.
- **음색**: `Song.swift` 하단의 `Patch` 값(파형, ADSR, 컷오프, 디튠)을 조절하면 됩니다.
- **실제 악기 소리**: `.sf2` SoundFont를 번들에 넣고 `AVAudioUnitSampler`로 교체할 수 있습니다.
  단, 샘플러는 렌더 콜백에서 직접 트리거할 수 없으므로 `AVAudioSequencer` 또는 `AVMusicTrack`에 노트를 넣고
  `startTime`을 `AVAudioTime(hostTime:)`으로 예약하는 구조로 바꿔야 합니다.
- **Ableton Link**: 다른 음악 앱과도 맞추고 싶다면 자체 시계 동기화 대신 LinkKit을 붙이면 됩니다.

## 알려진 한계

- 기기별 오디오 출력 지연 차이(수 ms)는 `outputLatency`로 보정하지만, Bluetooth 스피커/이어폰을 끼면
  그 기기만 100ms 이상 늦어집니다. 내장 스피커 기준으로 테스트하세요.
- Wi-Fi 없이 Bluetooth만으로 연결되면 RTT가 커져 동기화 오차가 커집니다. 로비의 "동기화 NNms" 표시가
  20ms 이하일 때 준비 버튼을 누르면 가장 잘 맞습니다.
- 앱이 백그라운드로 가면 MultipeerConnectivity 세션이 끊깁니다.
