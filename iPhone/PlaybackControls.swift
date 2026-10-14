import SwiftUI

struct PlaybackControls: View {
    @EnvironmentObject var store: PhoneStore
    let clip: Clip
    @State private var position = 0.0
    var body: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { position }, set: { value in position = value; store.seekPlayback(value) }), in: 0...max(clip.duration, 0.1))
                .disabled(store.playingID != clip.id).accessibilityLabel("播放进度")
            HStack {
                Text(String(format: "%.1f 秒", position))
                Spacer()
                Text(DisplayDuration.text(clip.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 32) {
                Button { store.seekPlayback(position - 15) } label: { Image(systemName: "gobackward.15").font(.title2).frame(minWidth: 44, minHeight: 44) }
                    .disabled(store.playingID != clip.id).accessibilityLabel("后退15秒")
                Spacer()
            Picker("倍速", selection: Binding(get: { store.playbackRate }, set: { value in
                store.playbackRate = value; store.player?.enableRate = true; store.player?.rate = value
            })) { ForEach([Float(0.75),1,1.25,1.5,2], id: \.self) { Text(String(format: "%g×", Double($0))).tag($0) } }
                .pickerStyle(.menu).labelsHidden().accessibilityLabel("播放倍速")
                Spacer()
                Button { store.seekPlayback(position + 15) } label: { Image(systemName: "goforward.15").font(.title2).frame(minWidth: 44, minHeight: 44) }
                    .disabled(store.playingID != clip.id).accessibilityLabel("前进15秒")
            }.buttonStyle(.borderless)
        }.onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard store.playingID == clip.id else { return }
            position = store.playbackOrigin + (store.player?.currentTime ?? 0)
            store.playbackPosition = position
            if store.player?.isPlaying != true { store.stopPlayback() }
        }
    }
}
extension PhoneStore {
    func seekPlayback(_ position: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, position - playbackOrigin), player.duration)
        playbackPosition = playbackOrigin + player.currentTime
    }
}
