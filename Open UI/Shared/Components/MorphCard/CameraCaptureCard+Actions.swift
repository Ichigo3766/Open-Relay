import AVFoundation
import SwiftUI
import UIKit

// MARK: - Camera Card Controls & Actions

private struct CameraControlItem {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
}

extension CameraCaptureCard {
    /// ⋯ button that springs open into a column of controls, one after another.
    var moreColumn: some View {
        // Ordered bottom → top (closest to ⋯ first) so they deal out upward.
        let items: [CameraControlItem] = [
            CameraControlItem(icon: "xmark", label: "Close camera", isActive: false) { onClose() },
            CameraControlItem(icon: "arrow.triangle.2.circlepath.camera", label: "Flip camera", isActive: false) { flip() },
            CameraControlItem(icon: flashOn ? "bolt.fill" : "bolt.slash.fill",
                              label: flashOn ? "Flash on" : "Flash off", isActive: flashOn) {
                withAnimation(MorphCardMetrics.controlSpring) { flashOn.toggle() }
            },
            CameraControlItem(icon: "doc.viewfinder", label: "Scan document", isActive: false) { enterScan() },
        ]
        return VStack(spacing: 12) {
            ForEach(Array(items.enumerated().reversed()), id: \.offset) { index, item in
                MorphRoundControl(systemImage: item.icon, isActive: item.isActive,
                                  accessibilityLabel: item.label, action: item.action)
                    .scaleEffect(showsControls ? 1 : 0.3, anchor: .bottom)
                    .offset(y: showsControls ? 0 : CGFloat(index + 1) * 56)
                    .opacity(showsControls ? 1 : 0)
                    .animation(
                        reduceMotion ? .easeOut(duration: 0.15)
                            : MorphCardMetrics.controlSpring.delay(showsControls ? Double(index) * 0.045 : 0),
                        value: showsControls
                    )
                    .allowsHitTesting(showsControls)
                    .accessibilityHidden(!showsControls)
            }
            MorphRoundControl(systemImage: showsControls ? "chevron.down" : "ellipsis",
                              isActive: showsControls,
                              accessibilityLabel: showsControls ? "Hide camera options" : "Camera options") {
                withAnimation(MorphCardMetrics.controlSpring) { showsControls.toggle() }
            }
        }
    }

    var permissionMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera access is off")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Allow camera access in Settings to take photos for your chats.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white))
            .foregroundStyle(.black)
            .buttonStyle(MorphPressStyle())
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 80)
    }

    // MARK: Actions

    func startCamera() async {
        if access == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted ? .authorized : .denied
        }
        guard access == .authorized else { return }
        camera.onQuadChange = { newQuad in quad = newQuad }
        camera.onGuidanceChange = { newGuidance in guidance = newGuidance }
        camera.onAutoCapture = {
            guard isScanning, !isCapturing else { return }
            takePhoto()
        }
        camera.start { ok, info in
            isRunning = ok
            zoomInfo = info
            zoom = 1
        }
    }

    func flip() {
        guard !isFlipping else { return }
        isFlipping = true
        camera.flip { info in
            withAnimation(MorphCardMetrics.controlSpring) {
                zoomInfo = info
                zoom = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { isFlipping = false }
        }
    }

    func takePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        Haptics.play(.medium)
        // Quick white flash.
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.85 }
        withAnimation(.easeIn(duration: 0.3).delay(0.06)) { flashOpacity = 0 }
        let scanning = isScanning
        camera.capture(flash: flashOn) { image in
            guard let image else {
                isCapturing = false
                Haptics.notify(.error)
                return
            }
            if scanning {
                addScannedPage(image)
                return
            }
            // Hold the shot in the card for a beat, then hand it to the composer
            // (the card shrinks back into the composer and the tile lands there).
            withAnimation(.easeOut(duration: 0.12)) { frozenFrame = image }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                onCapture(image)
            }
        }
    }
}
