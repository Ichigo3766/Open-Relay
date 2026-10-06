import AVFoundation
import CoreImage
import UIKit
import Vision

// MARK: - Camera Session Controller
//
// Thin AVFoundation wrapper used by the in-composer camera card. Session work runs
// on a private serial queue; results are delivered back on the main actor.

nonisolated final class CameraSessionController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    let queue = DispatchQueue(label: "com.openui.camera.session")
    let visionQueue = DispatchQueue(label: "com.openui.camera.vision")
    let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    var input: AVCaptureDeviceInput?
    private var isConfigured = false
    private var position: AVCaptureDevice.Position = .back
    /// queue-only: current zoom capabilities.
    var zoomInfo = CameraZoomInfo()

    // visionQueue-only state
    var scanEnabled = false
    var autoCaptureEnabled = true
    var lastVisionTime: CFTimeInterval = 0
    var lastQuad: DocumentQuad?
    var lastGuidance: ScanGuidance?
    var stableSince: CFTimeInterval?
    var autoCaptureCooldownUntil: CFTimeInterval = 0

    // queue-only state
    var pendingCaptures: [Int64: (UIImage?) -> Void] = [:]
    var pendingScanQuads: [Int64: DocumentQuad] = [:]

    /// Main-actor callbacks.
    var onQuadChange: (@MainActor @Sendable (DocumentQuad?) -> Void)?
    var onGuidanceChange: (@MainActor @Sendable (ScanGuidance) -> Void)?
    /// Fired when a steady document should be captured automatically.
    var onAutoCapture: (@MainActor @Sendable () -> Void)?

    // MARK: Lifecycle

    func start(completion: @escaping @MainActor @Sendable (Bool, CameraZoomInfo) -> Void) {
        queue.async { [self] in
            if !isConfigured { configure() }
            if !session.isRunning { session.startRunning() }
            // Always open on the main lens at 1× (some multi-lens cameras start
            // zoomed out on the ultra-wide once the session begins running).
            resetZoomToOne()
            let ok = input != nil
            let info = zoomInfo
            Task { @MainActor in completion(ok, info) }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = Self.device(for: position),
           let newInput = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        applyPortraitRotation()
        session.commitConfiguration()
        setUpZoom()
        isConfigured = true
    }

    private func applyPortraitRotation() {
        for connection in [photoOutput.connection(with: .video), videoOutput.connection(with: .video)] {
            guard let connection else { continue }
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
    }

    /// Back: the multi-lens virtual camera, so zooming switches lenses automatically.
    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
            .devices.first
    }

    // MARK: Flip

    /// Switches between the front and back cameras. Zoom resets to 1×.
    func flip(completion: @escaping @MainActor @Sendable (CameraZoomInfo) -> Void) {
        queue.async { [self] in
            let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
            guard let device = Self.device(for: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                let info = zoomInfo
                Task { @MainActor in completion(info) }
                return
            }
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
                position = newPosition
            } else if let input {
                session.addInput(input)
            }
            applyPortraitRotation()
            session.commitConfiguration()
            setUpZoom()
            let info = zoomInfo
            Task { @MainActor in completion(info) }
        }
    }
}
