import SwiftUI

// MARK: - Scan Mode Controls
//
// Mirrors the system document camera: Cancel · Auto/Manual · flash on top;
// page stack · shutter · Save at the bottom.

extension CameraCaptureCard {
    var scanControls: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Haptics.play(.light)
                    exitScan()
                } label: {
                    Text(scannedPages.isEmpty ? "Cancel" : "Discard")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                }
                .buttonStyle(MorphPressStyle())

                Spacer()

                Button {
                    Haptics.selection()
                    autoCapture.toggle()
                    camera.setAutoCapture(autoCapture)
                } label: {
                    Text(autoCapture ? "Auto" : "Manual")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(autoCapture ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            Capsule()
                                .fill(autoCapture ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.ultraThinMaterial))
                                .environment(\.colorScheme, .dark)
                        }
                }
                .buttonStyle(MorphPressStyle())
                .accessibilityLabel(autoCapture ? "Automatic capture on" : "Manual capture")
                .animation(MorphCardMetrics.controlSpring, value: autoCapture)

                Spacer()

                MorphRoundControl(systemImage: flashOn ? "bolt.fill" : "bolt.slash.fill", size: 34,
                                  isActive: flashOn,
                                  accessibilityLabel: flashOn ? "Flash on" : "Flash off") {
                    withAnimation(MorphCardMetrics.controlSpring) { flashOn.toggle() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            HStack(alignment: .center) {
                ScannedPageStack(pages: scannedPages)
                    .frame(width: 76, alignment: .leading)
                Spacer()
                shutter
                Spacer()
                Button {
                    Haptics.notify(.success)
                    finishScan()
                } label: {
                    Text(scannedPages.count > 1 ? "Save (\(scannedPages.count))" : "Save")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(MorphPressStyle())
                .opacity(scannedPages.isEmpty ? 0 : 1)
                .scaleEffect(scannedPages.isEmpty ? 0.6 : 1)
                .allowsHitTesting(!scannedPages.isEmpty)
                .frame(width: 76, alignment: .trailing)
                .animation(MorphCardMetrics.controlSpring, value: scannedPages.count)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .transition(.opacity)
    }

    // MARK: Scan actions

    func enterScan() {
        withAnimation(MorphCardMetrics.controlSpring) {
            showsControls = false
            isScanning = true
            guidance = .searching
        }
        if zoom != 1 { setZoom(1, animated: true) }
        camera.setScanning(true, autoCapture: autoCapture)
    }

    func exitScan() {
        camera.setScanning(false, autoCapture: autoCapture)
        withAnimation(MorphCardMetrics.controlSpring) {
            isScanning = false
            scannedPages = []
            quad = nil
        }
    }

    func finishScan() {
        guard !scannedPages.isEmpty else { return }
        let pages = scannedPages
        camera.setScanning(false, autoCapture: autoCapture)
        onScan(pages)
    }

    /// A page was captured: it shrinks into the stack and scanning continues.
    func addScannedPage(_ page: UIImage) {
        camera.pauseAutoCapture(for: 1.6)
        flyingPageLanded = false
        flyingPage = page
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                flyingPageLanded = true
            } completion: {
                flyingPage = nil
                withAnimation(MorphCardMetrics.controlSpring) { scannedPages.append(page) }
            }
        }
        isCapturing = false
        guidance = .searching
    }
}
