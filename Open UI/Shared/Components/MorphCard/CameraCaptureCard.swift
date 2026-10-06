import AVFoundation
import SwiftUI

// MARK: - Camera Capture Card
//
// The live viewfinder the composer morphs into.
// Photo mode: ‹ / shutter / ⋯ (scan, flash, flip, close), opens at 1×,
// and pinch-to-zoom.
// Scan mode: live document outline + guidance ("Position the document in view"),
// Auto / Manual capture, multi-page stack and Save. Multiple pages become one PDF.

struct CameraCaptureCard: View {
    /// Back to the + menu. Nil when the camera was opened directly (widget/Siri).
    var onBack: (() -> Void)?
    var onClose: () -> Void
    var onCapture: (UIImage) -> Void
    /// Scanned pages (in order), delivered when the user taps Save.
    var onScan: ([UIImage]) -> Void

    // State is internal (not private) so the extensions in sibling files can reach it.
    @State var camera = CameraSessionController()
    @State var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State var isRunning = false
    @State var showsControls = false
    @State var flashOn = false
    @State var isFlipping = false
    @State var flashOpacity: Double = 0
    @State var frozenFrame: UIImage?
    @State var isCapturing = false

    // Zoom
    @State var zoomInfo = CameraZoomInfo()
    @State var zoom: CGFloat = 1
    @State var pinchBaseZoom: CGFloat?

    // Scan
    @State var isScanning = false
    @State var autoCapture = true
    @State var quad: DocumentQuad?
    @State var guidance: ScanGuidance = .searching
    @State var scannedPages: [UIImage] = []
    /// Last captured page flying down into the page stack.
    @State var flyingPage: UIImage?
    @State var flyingPageLanded = false

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack {
            Color.black
            viewfinder
                .contentShape(Rectangle())
                .gesture(pinchToZoom)
            if isScanning && frozenFrame == nil {
                DocumentScanOverlay(quad: quad, guidance: guidance)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let flyingPage {
                flyingPageView(flyingPage)
            }
            Color.white.opacity(flashOpacity).allowsHitTesting(false)
            if isScanning { scanControls } else { photoControls }
        }
        .clipShape(RoundedRectangle(cornerRadius: MorphCardMetrics.cornerRadius, style: .continuous))
        .task { await startCamera() }
        .onDisappear { camera.stop() }
        .animation(MorphCardMetrics.controlSpring, value: isScanning)
    }

    // MARK: Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        switch access {
        case .authorized:
            ZStack {
                CameraPreviewView(session: camera.session)
                    .opacity(isRunning ? 1 : 0)
                    .blur(radius: isFlipping ? 24 : 0)
                    .scaleEffect(isFlipping ? 1.06 : 1)
                    .animation(.easeInOut(duration: 0.28), value: isFlipping)
                    .animation(.easeOut(duration: 0.3), value: isRunning)
                if let frozenFrame {
                    Image(uiImage: frozenFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
        case .denied, .restricted:
            permissionMessage
        default:
            ProgressView().tint(.white)
        }
    }

    /// The captured page shrinking from the middle of the card into the page stack.
    private func flyingPageView(_ image: UIImage) -> some View {
        GeometryReader { geo in
            let landed = flyingPageLanded
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: landed ? 44 : geo.size.width * 0.62,
                       height: landed ? 58 : geo.size.height * 0.55)
                .clipShape(RoundedRectangle(cornerRadius: landed ? 6 : 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .position(x: landed ? 18 + 22 : geo.size.width / 2,
                          y: landed ? geo.size.height - 18 - 36 : geo.size.height * 0.45)
                .opacity(landed ? 0 : 1)
        }
        .allowsHitTesting(false)
    }
}

