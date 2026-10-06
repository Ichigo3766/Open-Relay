import AVFoundation
import SwiftUI

// MARK: - Photo Controls + Pinch-to-Zoom

extension CameraCaptureCard {
    var photoControls: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if let onBack {
                    MorphRoundControl(systemImage: "chevron.left", accessibilityLabel: "Back") { onBack() }
                } else {
                    MorphRoundControl(systemImage: "xmark", accessibilityLabel: "Close camera") { onClose() }
                }
                Spacer()
                shutter
                Spacer()
                moreColumn
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .transition(.opacity)
    }

    var shutter: some View {
        Button {
            takePhoto()
        } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                Circle().fill(Color.white).frame(width: 58, height: 58)
            }
            .contentShape(Circle())
        }
        .buttonStyle(MorphPressStyle(scale: 0.88))
        .disabled(access != .authorized || isCapturing)
        .accessibilityLabel(isScanning ? "Capture page" : "Take photo")
    }

    // MARK: Pinch

    var pinchToZoom: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchBaseZoom == nil { pinchBaseZoom = zoom }
                setZoom((pinchBaseZoom ?? zoom) * value.magnification, animated: false)
            }
            .onEnded { _ in pinchBaseZoom = nil }
    }

    /// Sets the zoom (display units, 1 = main lens) and clamps it to what the
    /// camera supports. A light tick plays when pinching back through 1×.
    func setZoom(_ value: CGFloat, animated: Bool) {
        let clamped = min(max(value, zoomInfo.minDisplay), zoomInfo.maxDisplay)
        let crossedOne = (zoom < 0.999 && clamped >= 0.999) || (zoom > 1.001 && clamped <= 1.001)
        if crossedOne && !animated { Haptics.selection() }
        if animated {
            withAnimation(MorphCardMetrics.controlSpring) { zoom = clamped }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { zoom = clamped }
        }
        camera.setZoom(display: clamped, animated: animated)
    }
}
