import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision

// MARK: - Capture

nonisolated extension CameraSessionController {
    /// Captures a still. In scan mode the page is found again on the full-resolution
    /// still (falling back to the live outline), then cropped, perspective-corrected
    /// and enhanced like a scanned document.
    func capture(flash: Bool, completion: @escaping @MainActor @Sendable (UIImage?) -> Void) {
        visionQueue.async { [self] in
            let quad = scanEnabled ? lastQuad : nil
            let scanning = scanEnabled
            queue.async { [self] in
                guard input != nil else {
                    Task { @MainActor in completion(nil) }
                    return
                }
                let settings = AVCapturePhotoSettings()
                if photoOutput.supportedFlashModes.contains(.on) {
                    settings.flashMode = flash ? .on : .off
                }
                settings.photoQualityPrioritization = scanning ? .quality : .balanced
                if settings.photoQualityPrioritization.rawValue > photoOutput.maxPhotoQualityPrioritization.rawValue {
                    settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
                }
                pendingCaptures[settings.uniqueID] = { image in
                    Task { @MainActor in completion(image) }
                }
                if scanning {
                    // Sentinel quad when nothing is outlined: still try detection on the still.
                    pendingScanQuads[settings.uniqueID] = quad ?? DocumentQuad(
                        topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)
                }
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private static let ciContext = CIContext()

    /// Finds the document on a full-resolution image.
    static func detectDocument(in image: CIImage) -> DocumentQuad? {
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        guard let result = request.results?.first, result.confidence > 0.5 else { return nil }
        let quad = DocumentQuad(topLeft: result.topLeft, topRight: result.topRight,
                                bottomRight: result.bottomRight, bottomLeft: result.bottomLeft)
        return quad.area > 0.04 ? quad : nil
    }

    /// Crops + flattens the page and lifts it like a scanner (clean whites, crisp text).
    static func scannedPage(from data: Data, liveQuad: DocumentQuad?) -> UIImage? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let live = liveQuad.flatMap { $0.area > 0.04 ? $0 : nil }
        guard let quad = detectDocument(in: source) ?? live else { return nil }

        let extent = source.extent
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + p.y * extent.height)
        }
        let flatten = CIFilter.perspectiveCorrection()
        flatten.inputImage = source
        flatten.topLeft = point(quad.topLeft)
        flatten.topRight = point(quad.topRight)
        flatten.bottomRight = point(quad.bottomRight)
        flatten.bottomLeft = point(quad.bottomLeft)
        guard var output = flatten.outputImage else { return nil }

        let enhance = CIFilter.documentEnhancer()
        enhance.inputImage = output
        enhance.amount = 1
        if let enhanced = enhance.outputImage { output = enhanced }

        guard let cg = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

nonisolated extension CameraSessionController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = photo.fileDataRepresentation()
        queue.async { [self] in
            let completion = pendingCaptures.removeValue(forKey: id)
            let quad = pendingScanQuads.removeValue(forKey: id)
            guard let data else { completion?(nil); return }
            var image: UIImage?
            if let quad { image = Self.scannedPage(from: data, liveQuad: quad) }
            if image == nil { image = UIImage(data: data) }
            completion?(image)
        }
    }
}


// MARK: - Live document detection + guidance

nonisolated extension CameraSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// How long the page has to stay put before auto-capture fires.
    private static let steadyDuration: CFTimeInterval = 1.0

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard scanEnabled, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        guard now - lastVisionTime > 0.08 else { return }
        lastVisionTime = now

        // Document segmentation (the model the system scanner uses) finds pages
        // even with low contrast / curled corners; rectangles are a fallback.
        let segmentation = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 1
        rectangles.minimumConfidence = 0.75
        rectangles.minimumAspectRatio = 0.3
        rectangles.quadratureTolerance = 20
        rectangles.minimumSize = 0.2
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            .perform([segmentation, rectangles])

        var detected: DocumentQuad?
        if let doc = segmentation.results?.first, doc.confidence > 0.6 {
            detected = DocumentQuad(topLeft: doc.topLeft, topRight: doc.topRight,
                                    bottomRight: doc.bottomRight, bottomLeft: doc.bottomLeft)
        } else if let rect = rectangles.results?.first {
            detected = DocumentQuad(topLeft: rect.topLeft, topRight: rect.topRight,
                                    bottomRight: rect.bottomRight, bottomLeft: rect.bottomLeft)
        }
        guard scanEnabled else { return }

        // Smooth the outline so it glides instead of jittering.
        var quad = detected
        if let new = detected, let old = lastQuad, new.distance(to: old) < 0.12 {
            quad = Self.blend(old, new, 0.45)
        }

        // Guidance + steadiness.
        let guidance: ScanGuidance
        if let quad {
            if quad.area < 0.12 {
                guidance = .moveCloser
                stableSince = nil
            } else if let old = lastQuad, quad.distance(to: old) < 0.02 {
                if stableSince == nil { stableSince = now }
                guidance = .holdSteady
            } else {
                stableSince = now
                guidance = .holdSteady
            }
        } else {
            guidance = .searching
            stableSince = nil
        }

        let previous = lastQuad
        lastQuad = quad
        if quad != previous {
            let callback = onQuadChange
            let published = quad
            Task { @MainActor in callback?(published) }
        }

        var finalGuidance = guidance
        if autoCaptureEnabled, guidance == .holdSteady, let since = stableSince,
           now - since >= Self.steadyDuration, now > autoCaptureCooldownUntil {
            autoCaptureCooldownUntil = now + 2.0
            stableSince = nil
            finalGuidance = .capturing
            let fire = onAutoCapture
            Task { @MainActor in fire?() }
        }
        if finalGuidance != lastGuidance {
            lastGuidance = finalGuidance
            let callback = onGuidanceChange
            let published = finalGuidance
            Task { @MainActor in callback?(published) }
        }
    }

    private static func blend(_ a: DocumentQuad, _ b: DocumentQuad, _ t: CGFloat) -> DocumentQuad {
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
            CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        }
        return DocumentQuad(topLeft: mix(a.topLeft, b.topLeft), topRight: mix(a.topRight, b.topRight),
                            bottomRight: mix(a.bottomRight, b.bottomRight),
                            bottomLeft: mix(a.bottomLeft, b.bottomLeft))
    }

    /// Turns scan mode on/off and sets whether steady pages capture automatically.
    func setScanning(_ enabled: Bool, autoCapture: Bool) {
        visionQueue.async { [self] in
            scanEnabled = enabled
            autoCaptureEnabled = autoCapture
            stableSince = nil
            lastGuidance = nil
            autoCaptureCooldownUntil = CACurrentMediaTime() + 0.8
            if !enabled {
                lastQuad = nil
                let callback = onQuadChange
                Task { @MainActor in callback?(nil) }
            }
        }
    }

    func setAutoCapture(_ enabled: Bool) {
        visionQueue.async { [self] in
            autoCaptureEnabled = enabled
            stableSince = nil
        }
    }

    /// Short pause after a page is captured so the same page isn't grabbed twice.
    func pauseAutoCapture(for seconds: CFTimeInterval) {
        visionQueue.async { [self] in
            autoCaptureCooldownUntil = CACurrentMediaTime() + seconds
            stableSince = nil
        }
    }
}

// MARK: - Preview view

/// Live camera preview filling its bounds (aspect-fill).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}
