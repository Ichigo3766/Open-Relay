import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// A seekable session of completed speech files. Synthesis stays in Open WebUI.
@MainActor @Observable
final class ReadAloudPlayer {
    typealias Prepare = @MainActor () async throws -> [String]
    typealias Generate = @MainActor (String) async throws -> (Data, String)

    private(set) var messageID: String?
    private(set) var title = "Read Aloud"
    private(set) var transcript = ""
    private(set) var elapsed: Double = 0
    private(set) var bufferedDuration: Double = 0
    private(set) var duration: Double?
    private(set) var wantsPlayback = false
    private(set) var isPlaying = false
    private(set) var isGenerating = false
    private(set) var error: String?
    private(set) var rate: Float = 1
    var isVisible: Bool { messageID != nil }
    var canSeek: Bool { bufferedDuration > 0 }
    var isFinished: Bool { duration != nil && elapsed >= (duration ?? 0) && error == nil }

    private struct Segment {
        let url: URL
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var segments: [Segment] = []
    @ObservationIgnored private var itemIndices: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var seekID = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var chunks: [String] = []
    @ObservationIgnored private var nextChunk = 0
    @ObservationIgnored private var prepare: Prepare?
    @ObservationIgnored private var generate: Generate?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var playerObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
    @ObservationIgnored private var requiresRestart = false
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func start(messageID: String, title: String, prepare: @escaping Prepare, generate: @escaping Generate) {
        stop()
        self.messageID = messageID
        self.title = title
        self.prepare = prepare
        self.generate = generate
        let saved = UserDefaults.standard.float(forKey: "readAloudPlaybackRate")
        rate = [1, 1.25, 1.5, 1.75, 2].contains(saved) ? saved : 1
        wantsPlayback = true
        installObservers()
        installRemoteCommands()
        produce()
    }

    private func produce() {
        let id = sessionID
        error = nil
        isGenerating = true
        beginBackgroundTask()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .spokenAudio)
                try audio.setActive(true)
                if chunks.isEmpty, let prepare {
                    let prepared = try await prepare()
                    try Task.checkCancellation()
                    guard sessionID == id else { return }
                    guard !prepared.isEmpty else { throw PlaybackError.emptyText }
                    chunks = prepared
                    transcript = prepared.joined(separator: "\n\n")
                }
                if directory == nil {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-aloud-\(id)")
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    directory = url
                }
                while nextChunk < chunks.count, let generate, let directory {
                    let (data, contentType) = try await generate(chunks[nextChunk])
                    try Task.checkCancellation()
                    guard sessionID == id else { return }
                    let url = directory.appendingPathComponent("\(nextChunk).\(Self.audioExtension(contentType))")
                    try data.write(to: url, options: .atomic)
                    let asset = AVURLAsset(url: url)
                    let length = try await asset.load(.duration).seconds
                    try Task.checkCancellation()
                    guard sessionID == id else { return }
                    guard length.isFinite, length > 0 else { throw PlaybackError.invalidAudio }
                    segments.append(Segment(url: url, start: bufferedDuration, duration: length))
                    bufferedDuration += length
                    nextChunk += 1
                    enqueue(segments.count - 1)
                    playIfRequested()
                }
                guard sessionID == id else { return }
                isGenerating = false
                duration = bufferedDuration
                endBackgroundTask()
                updatePosition()
            } catch {
                guard sessionID == id, !Task.isCancelled else { return }
                isGenerating = false
                self.error = "Couldn’t prepare audio. Retry, or choose smaller text chunks in Settings."
                pause()
                endBackgroundTask()
            }
        }
    }

    func retry() {
        guard error != nil else { return }
        if requiresRestart, let messageID, let prepare, let generate {
            start(messageID: messageID, title: title, prepare: prepare, generate: generate)
            return
        }
        wantsPlayback = true
        if canSeek { seek(to: elapsed) }
        produce()
    }

    func togglePlayback() { wantsPlayback ? pause() : resume() }
    func pause() {
        wantsPlayback = false
        player.pause()
        updatePosition()
    }
    func resume() {
        guard isVisible, error == nil else { return }
        wantsPlayback = true
        if isFinished { seek(to: 0) }
        else { playIfRequested() }
    }
    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 1.75, 2]
        rate = rates[((rates.firstIndex(of: rate) ?? 0) + 1) % rates.count]
        UserDefaults.standard.set(rate, forKey: "readAloudPlaybackRate")
        playIfRequested()
        updateNowPlaying()
    }
    func skip(_ seconds: Double) { seek(to: elapsed + seconds) }

    func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite else { return }
        let target = min(max(0, seconds), bufferedDuration)
        let id = UUID()
        seekID = id
        isSeeking = true
        player.pause()
        player.removeAllItems()
        itemIndices.removeAll()
        elapsed = target
        guard let index = segments.firstIndex(where: { target < $0.end }) else {
            isSeeking = false
            updatePosition()
            return
        }
        for i in index..<segments.count { enqueue(i) }
        player.seek(to: CMTime(seconds: target - segments[index].start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekID == id else { return }
                self.isSeeking = false
                self.playIfRequested()
                self.updatePosition()
            }
        }
    }

    func stop() {
        let wasVisible = isVisible
        sessionID = UUID()
        seekID = UUID()
        task?.cancel()
        task = nil
        player.pause()
        player.removeAllItems()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        playerObservers.removeAll()
        itemObserver = nil
        requiresRestart = false
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        if wasVisible {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        endBackgroundTask()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        segments.removeAll()
        itemIndices.removeAll()
        chunks.removeAll()
        nextChunk = 0
        prepare = nil
        generate = nil
        messageID = nil
        transcript = ""
        elapsed = 0
        bufferedDuration = 0
        duration = nil
        wantsPlayback = false
        isPlaying = false
        isGenerating = false
        isSeeking = false
        error = nil
    }

    private func enqueue(_ index: Int) {
        let item = AVPlayerItem(url: segments[index].url)
        item.audioTimePitchAlgorithm = .timeDomain
        itemIndices[ObjectIdentifier(item)] = index
        player.insert(item, after: nil)
    }
    private func playIfRequested() {
        if wantsPlayback, !isSeeking, player.currentItem != nil {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.playImmediately(atRate: rate)
        }
        updateNowPlaying()
    }
    private func updatePosition() {
        guard isVisible else { return }
        if !isSeeking, let item = player.currentItem, let index = itemIndices[ObjectIdentifier(item)] {
            let time = player.currentTime().seconds
            if time.isFinite { elapsed = min(segments[index].end, segments[index].start + max(0, time)) }
        }
        isPlaying = player.timeControlStatus == .playing
        if player.currentItem == nil, !isGenerating, error == nil, duration != nil {
            elapsed = bufferedDuration
            wantsPlayback = false
            isPlaying = false
        }
        updateNowPlaying()
    }

    private func installObservers() {
        // The periodic observer stops when the queue drains, so observe the final
        // item transition as well as playback stalls and resumes.
        playerObservers = [
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.observeCurrentItem()
                    self?.updatePosition()
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updatePosition() }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePosition() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, let index = self.itemIndices[ObjectIdentifier(item)] else { return }
                self.elapsed = self.segments[index].end
                self.updatePosition()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, self.itemIndices[ObjectIdentifier(item)] != nil else { return }
                self.playbackFailed()
            }
        })
    }

    private func observeCurrentItem() {
        itemObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.playbackFailed()
            }
        }
    }
    private func playbackFailed() {
        task?.cancel()
        task = nil
        isGenerating = false
        requiresRestart = true
        error = "Audio playback failed. Retry to prepare the audio again."
        pause()
        endBackgroundTask()
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ReadAloudPlayer, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.isVisible else { return }
                    action(self, event)
                }
                return .success
            }
            remoteTargets.append((command, target))
        }
        bind(center.playCommand) { p, _ in p.resume() }
        bind(center.pauseCommand) { p, _ in p.pause() }
        bind(center.togglePlayPauseCommand) { p, _ in p.togglePlayback() }
        bind(center.skipBackwardCommand) { p, _ in p.skip(-15) }
        bind(center.skipForwardCommand) { p, _ in p.skip(15) }
        bind(center.changePlaybackPositionCommand) { p, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { p.seek(to: event.positionTime) }
        }
    }
    private func updateNowPlaying() {
        guard isVisible else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.isEnabled = canSeek
        commands.skipForwardCommand.isEnabled = canSeek
        commands.changePlaybackPositionCommand.isEnabled = duration != nil
    }
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ReadAloudPreparation") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundTask() }
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    private static func audioExtension(_ contentType: String) -> String {
        let type = contentType.lowercased()
        if type.contains("wav") { return "wav" }
        if type.contains("mp4") || type.contains("m4a") { return "m4a" }
        if type.contains("aac") { return "aac" }
        if type.contains("flac") { return "flac" }
        if type.contains("ogg") || type.contains("opus") { return "ogg" }
        return "mp3"
    }
    private enum PlaybackError: Error { case emptyText, invalidAudio }
}
