import Foundation
import UIKit
import os.log

// MARK: - Keeping the call's engines in sync

/// The call always uses the engines the user chose — within what the app's
/// state allows:
/// - **Background**: on-device (GPU) models can't run, so the voice moves to
///   the server (system voice as a per-sentence safety net) and listening
///   moves to the server / Apple Speech.
/// - **Foreground again**: the chosen on-device models are reloaded and
///   swapped back in once ready; the stand-ins keep talking meanwhile.
/// - **Settings changed mid-call** (Settings or the in-call Voice sheet):
///   applied right away — a new voice speaks from the next sentence, a new
///   listening engine takes over without losing what the user is saying.
extension VoiceCallViewModel {

    var isInForeground: Bool { UIApplication.shared.applicationState == .active }

    /// The engines the call should use now (or, with `inForeground: true`,
    /// what the user chose — used for the stand-in notice).
    func currentSelection(inForeground: Bool? = nil) -> CallEngineSelection {
        CallEngineSelection.resolve(
            settings: settings, ttsService: ttsService,
            hasServer: apiClientProvider() != nil, inForeground: inForeground ?? isInForeground,
            onDeviceLoaded: (orchestrator?.currentTTS as? MLXCallTTSEngine)?.model ?? autoModelLoaded
        )
    }

    /// Refreshes notices after recording the starting engine signatures.
    func startEngineSync() {
        orchestrator?.onEnginesChanged = { [weak self] in self?.refreshEngineNotice() }
        refreshEngineNotice()
    }

    func stopEngineSync() {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        engineSyncTask?.cancel()
        engineSyncTask = nil
        syncTarget = nil
        debounceTask?.cancel()
        debounceTask = nil
        engineNotice = nil
        autoModelLoaded = nil
    }

    /// Settings are written in bursts (sliders, pickers writing several
    /// keys): wait for them to settle before comparing.
    func scheduleEngineSync() {
        guard orchestrator != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.syncEngines()
        }
    }

    /// App is resigning active: the GPU gate closes now, and the on-device
    /// voice is replaced synchronously with an instant stand-in (so no
    /// sentence waits on the network); the server voice follows moments
    /// later from `syncEngines()`.
    func enterBackground() {
        MLXCallLock.gpuAllowed = false
        engineSyncTask?.cancel()
        engineSyncTask = nil
        syncTarget = nil
        guard let orch = orchestrator else { return }
        if let mlx = orch.currentTTS as? MLXCallTTSEngine {
            // Auto mode: remember the model the call was using so it's still
            // "ready" (and comes back) when the app returns.
            autoModelLoaded = mlx.model
            orch.replaceTTS(CallEngineFactory.makeSystemTTS(), signature: "standin|system")
        }
        syncEngines()
    }

    func enterForeground() {
        MLXCallLock.gpuAllowed = true
        syncEngines()
    }

    /// Updates the "using X while…" line on the call screen.
    /// Shown only while a stand-in is *actually* speaking/listening, so it
    /// stays up until the user's own engine has finished reloading.
    func refreshEngineNotice() {
        guard let orch = orchestrator else { engineNotice = nil; return }
        let wanted = currentSelection(inForeground: true)
        let notice: String?
        if orch.ttsSignature != wanted.voiceSignature, wanted.voice != .system {
            let usingServer = orch.currentTTS is FallbackCallTTSEngine || orch.currentTTS is ServerCallTTSEngine
            let reason = isInForeground ? "while your voice loads" : "while in background"
            notice = "Using \(usingServer ? "server" : "system") voice \(reason)"
        } else if orch.sttSignature != wanted.listeningSignature, wanted.listening != .apple {
            let reason = isInForeground ? "while your model loads" : "while in background"
            notice = "Using \(orch.stt is ServerCallSTTEngine ? "server" : "Apple Speech") listening \(reason)"
        } else {
            notice = nil
        }
        if engineNotice != notice { engineNotice = notice }
    }

    /// Compares the wanted engines with the ones in use and swaps what
    /// changed. Loads run off the call's critical path; a newer sync cancels
    /// an older one, and a result is dropped if the wanted engine changed
    /// while it loaded (e.g. backgrounded again during a reload).
    func syncEngines() {
        guard let orch = orchestrator else { return }
        let selection = currentSelection()
        defer { refreshEngineNotice() }

        // Same on-device model, new voice / speed / language: apply to the
        // loaded model — no reload, the next sentence uses it.
        if selection.voiceSignature != orch.ttsSignature,
           case .onDevice(let model) = selection.voice,
           let mlx = orch.currentTTS as? MLXCallTTSEngine, mlx.model == model {
            var config = ttsService.kokoroService.config
            config.activeModel = model
            mlx.updateVoice(from: config)
            orch.ttsSignature = selection.voiceSignature
            logger.info("Call voice updated in place (\(model.displayName, privacy: .public))")
        }

        let needsTTS = selection.voiceSignature != orch.ttsSignature
        let needsSTT = selection.listeningSignature != orch.sttSignature
        guard needsTTS || needsSTT else {
            engineSyncTask?.cancel()
            engineSyncTask = nil
            syncTarget = nil
            return
        }
        // Already loading exactly this (settings writes arrive in bursts):
        // don't restart a model load that's halfway done.
        let target = "\(needsTTS ? selection.voiceSignature : "")#\(needsSTT ? selection.listeningSignature : "")"
        if engineSyncTask != nil, syncTarget == target { return }

        engineSyncTask?.cancel()
        syncTarget = target
        let api = apiClientProvider()
        engineSyncTask = Task { [weak self] in
            if needsTTS { await self?.swapVoice(to: selection, api: api) }
            if !Task.isCancelled, needsSTT { await self?.swapListening(to: selection, api: api) }
            guard !Task.isCancelled, let self else { return }
            self.engineSyncTask = nil
            self.syncTarget = nil
            self.refreshEngineNotice()
        }
    }

    private func swapVoice(to selection: CallEngineSelection, api: APIClient?) async {
        let engine = await CallEngineFactory.makeTTS(for: selection, apiClient: api, ttsService: ttsService)
        guard !Task.isCancelled, let orch = orchestrator,
              currentSelection().voiceSignature == selection.voiceSignature else {
            engine?.shutdown()
            return
        }
        guard let engine else {
            logger.error("Call voice unavailable — keeping \(orch.currentTTS.displayName, privacy: .public)")
            return
        }
        orch.replaceTTS(engine, signature: selection.voiceSignature)
    }

    private func swapListening(to selection: CallEngineSelection, api: APIClient?) async {
        let engine = await CallEngineFactory.makeSTT(for: selection, apiClient: api)
        guard !Task.isCancelled, let orch = orchestrator,
              currentSelection().listeningSignature == selection.listeningSignature else {
            engine?.shutdown()
            return
        }
        guard let engine else {
            logger.error("Call listening unavailable — keeping \(orch.sttDisplayName, privacy: .public)")
            return
        }
        orch.replaceSTT(engine, signature: selection.listeningSignature)
        isUsingServerSTT = engine is ServerCallSTTEngine
    }
}
