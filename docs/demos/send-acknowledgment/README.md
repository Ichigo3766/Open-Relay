# Synthetic chat demo

All prompts, answers and model labels in these assets are freshly invented. The recording opens an uncached synthetic chat, sends a new message, retains its composer text during an eight-second completion-acknowledgment delay, then displays the answer with the acknowledged draft cleared.

The recording uses the combined discovery and acknowledgment candidate. It demonstrates the flow; it is not a latency benchmark. Performance measurements are reported in the pull request. Image/video metadata is stripped and the video has no audio.

The double-tap assets use a fresh invented lantern prompt. The control uses staggered one/three-second model-discovery replies, a four-second history-save delay and an eight-second generation receipt delay: two taps produce a submitted turn plus a queued copy. The fixed recording retains the draft without a queue entry until the receipt arrives. Before/after PNGs and the recording are synthetic only, with stripped metadata and no audio.
