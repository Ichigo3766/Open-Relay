import AVFoundation
import UIKit

// MARK: - Zoom

nonisolated extension CameraSessionController {
    /// Reads the active device's lenses and sets the display scale so 1× is the
    /// main (wide) lens, like the Camera app. Pinching can still go down to the
    /// ultra-wide (0.5×) and up to the telephoto / digital range.
    func setUpZoom() {
        guard let device = input?.device else {
            zoomInfo = CameraZoomInfo()
            return
        }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }

        // With an ultra-wide, the wide lens sits at the first switch-over factor.
        let multiplier: CGFloat = hasUltraWide ? (switchOvers.first ?? 2) : 1
        let minDevice = device.minAvailableVideoZoomFactor
        // Cap like the Camera app (digital zoom past ~5× the longest lens is mush).
        let longest = (switchOvers.last ?? multiplier) / multiplier
        let maxDisplay = min(device.maxAvailableVideoZoomFactor / multiplier, max(longest * 5, 10))

        zoomInfo = CameraZoomInfo(
            multiplier: multiplier,
            minDisplay: minDevice / multiplier,
            maxDisplay: max(1, maxDisplay)
        )
        resetZoomToOne()
    }

    /// Puts the camera back on the main lens at 1×.
    func resetZoomToOne() {
        guard let device = input?.device else { return }
        setDeviceZoom(zoomInfo.multiplier, device: device, animated: false)
    }

    /// Sets zoom in display units. `animated` ramps smoothly (e.g. resetting for scans); live
    /// pinching sets it directly so it tracks the fingers.
    func setZoom(display: CGFloat, animated: Bool) {
        queue.async { [self] in
            guard let device = input?.device else { return }
            setDeviceZoom(display * zoomInfo.multiplier, device: device, animated: animated)
        }
    }

    private func setDeviceZoom(_ factor: CGFloat, device: AVCaptureDevice, animated: Bool) {
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor),
                          zoomInfo.maxDisplay * zoomInfo.multiplier,
                          device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 18)
            } else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        } catch {}
    }
}
