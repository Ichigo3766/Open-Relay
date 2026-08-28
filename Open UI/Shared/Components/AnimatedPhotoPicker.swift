import SwiftUI
import Photos
import PhotosUI

// MARK: - Animated Photo Picker
//
// A custom bottom-panel photo picker that replaces the system PhotosPicker.
// Springs up from the bottom with a frosted-glass card, shows a 3-column
// photo grid with numbered multi-select badges, and confirms with an animated
// "Add N Photos" pill. Designed to feel like the ChatGPT attachment flow.
//
// The panel covers 82% of screen height pinned to the physical bottom edge
// (ignoresSafeArea), overlapping the keyboard and input bar. The keyboard is
// dismissed when the panel opens. A "Browse All" button opens the full system
// PHPickerViewController for albums and older photos.

// MARK: - Photo Asset Model

struct PickerPhotoAsset: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    var thumbnail: UIImage?

    static func == (lhs: PickerPhotoAsset, rhs: PickerPhotoAsset) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Main Animated Photo Picker

struct AnimatedPhotoPicker: View {
    var isPresented: Bool
    var onConfirm: ([PHAsset]) -> Void
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme

    @State private var assets: [PickerPhotoAsset] = []
    @State private var selectedIds: [String] = []
    @State private var hasAccess = false
    @State private var loading = true
    @State private var isVisible = false
    @State private var dragOffset: CGFloat = 0
    @State private var pillScale: CGFloat = 1.0
    @State private var showSystemPicker = false

    // Shared caching image manager — pre-decodes thumbnails for the visible
    // viewport and cancels requests for cells that scroll off-screen.
    // Lives on the view struct so it persists across re-renders.
    private let imageManager = PHCachingImageManager()

    private var selectedCount: Int { selectedIds.count }
    // 82% of screen height; bottom is flush with the physical screen edge so
    // the panel always covers the input bar and safe-area home indicator region.
    private var panelHeight: CGFloat { UIScreen.main.bounds.height * 0.82 }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Layer 1: dim backdrop ─────────────────────────────────────────
            if isVisible {
                Color.black.opacity(0.50)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .transition(.opacity)
            }

            // ── Layer 2: frosted-glass photo grid panel ───────────────────────
            if isVisible {
                panelContent
                    .offset(y: max(0, dragOffset))
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom),
                        removal:   .move(edge: .bottom)
                    ))
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if v.translation.height > 0 { dragOffset = v.translation.height }
                            }
                            .onEnded { v in
                                if v.translation.height > 120 {
                                    dismiss()
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }

            // ── Layer 3: floating bottom bar (SIBLING, not child of panel) ────
            // Sits in the ZStack above the clipped panel card so it can never be
            // eaten by clipShape. Mirrors PhotoGridBar placement in the Expo
            // reference (chatgpt-attachments-screen.tsx / photo-grid.tsx).
            if isVisible {
                floatingBottomBar
                    .offset(y: max(0, dragOffset))
                    .padding(.bottom, 24)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        // Cover the entire screen including safe areas so the panel sits over
        // the input bar and home-indicator region.
        .ignoresSafeArea(.all)
        .onChange(of: isPresented) { _, newValue in
            if newValue { show() } else { hidePanel() }
        }
        .task(id: isPresented) {
            // Start loading immediately when isPresented flips true — even before
            // the panel spring animation finishes (~420ms). By the time the panel
            // is fully open the first viewport of thumbnails is already decoded.
            if isPresented { await loadPhotos() }
        }
        // System PHPickerViewController sheet for "Browse All"
        .sheet(isPresented: $showSystemPicker) {
            SystemPhotoPicker(selectionLimit: 20) { phAssets in
                showSystemPicker = false
                if !phAssets.isEmpty {
                    hidePanel { onConfirm(phAssets) }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Panel Content

    private var panelContent: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // Header
            HStack {
                Text("Photos")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                // Browse All — opens native PHPickerViewController with full album access
                Button {
                    Haptics.play(.light)
                    showSystemPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 13, weight: .medium))
                        Text("Browse All")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)

                if selectedCount > 0 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedIds.removeAll()
                        }
                        Haptics.play(.light)
                    } label: {
                        Text("Clear")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .animation(.easeOut(duration: 0.18), value: selectedCount)

            // Grid — fills remaining height; bottom spacer keeps last row visible above floating bar
            Group {
                if loading {
                    loadingGrid
                } else if !hasAccess {
                    noAccessView
                } else {
                    photoGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: panelHeight)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.black.opacity(0.55))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Photo Grid

    // Target size matches cell display size: screen-width ÷ 3 columns × screen scale.
    // Smaller than before (was 200×200) so PHImageManager decodes less per cell.
    private var thumbSize: CGSize {
        let side = UIScreen.main.bounds.width / 3 * UIScreen.main.scale
        return CGSize(width: side, height: side)
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { idx, photo in
                    PhotoGridCell(
                        photo: photo,
                        selectionOrder: selectionOrder(for: photo.id),
                        imageManager: imageManager,
                        targetSize: thumbSize,
                        onTap: { toggleSelection(photo.id) }
                    )
                    .onAppear {
                        // Pre-cache upcoming cells as they scroll into view
                        let start = max(0, idx - 3)
                        let end   = min(assets.count, idx + 15)
                        let upcoming = assets[start..<end].map(\.asset)
                        imageManager.startCachingImages(
                            for: upcoming,
                            targetSize: thumbSize,
                            contentMode: .aspectFill,
                            options: cachingOptions
                        )
                    }
                    .onDisappear {
                        // Release cache for cells far off-screen to save memory
                        imageManager.stopCachingImages(
                            for: [photo.asset],
                            targetSize: thumbSize,
                            contentMode: .aspectFill,
                            options: cachingOptions
                        )
                    }
                }
                // Invisible spacer — keeps the last photo row scrollable above
                // the floating bar (56pt pill + 16pt inset + 12pt gap = 84pt).
                Color.clear
                    .frame(height: 84)
                    .gridCellColumns(3)
            }
        }
        .scrollIndicators(.hidden)
    }

    // Reusable options for PHCachingImageManager — opportunistic quality so
    // cached images are at least a decent intermediate resolution (not the
    // lowest-quality "fast format" that was causing blurry thumbnails).
    private var cachingOptions: PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode    = .opportunistic
        o.resizeMode      = .fast
        o.isNetworkAccessAllowed = false
        o.isSynchronous   = false
        return o
    }

    // MARK: - Loading Skeleton

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<18, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .aspectRatio(1, contentMode: .fit)
                        .shimmering()
                }
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }

    // MARK: - No Access

    private var noAccessView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.4))
            Text("Photo access required")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.blue)
            Spacer()
        }
    }
}

// MARK: - Floating Bottom Bar
//
// Rendered as a ZStack sibling ABOVE the panel — completely outside the
// panel's clipShape. Mirrors PhotoGridBar in chatgpt-attachments-screen.tsx.

extension AnimatedPhotoPicker {

    /// Full-width row: ✕ clear chip (left) + Add N Photos pill (right).
    var floatingBottomBar: some View {
        HStack(alignment: .center) {
            if selectedCount > 0 {
                clearChip
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity),
                        removal:   .scale(scale: 0.7, anchor: .leading).combined(with: .opacity)
                    ))
            }
            Spacer()
            if selectedCount > 0 {
                addPill
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .trailing).combined(with: .opacity),
                        removal:   .scale(scale: 0.7, anchor: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: selectedCount > 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: selectedCount)
    }

    /// Small glass chip on the left — tapping it clears all selections.
    var clearChip: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedIds.removeAll()
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text("\(selectedCount)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Capsule()
                    .fill(Color.white.opacity(0.10))
            }
        }
        .buttonStyle(PillPressStyle())
    }

    /// Blue glass pill on the right — confirms the selection.
    var addPill: some View {
        Button {
            confirmSelection()
        } label: {
            HStack(spacing: 7) {
                Text(selectedCount == 1 ? "Add 1 Photo" : "Add \(selectedCount) Photos")
                    .contentTransition(.numericText())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                // Glass base samples whatever is behind (photos / dark panel)
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                // Blue accent over the glass — matches ChatGPT blue
                Capsule()
                    .fill(Color(red: 0.02, green: 0.47, blue: 1.0).opacity(0.88))
            }
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 6)
            .scaleEffect(pillScale)
        }
        .buttonStyle(PillPressStyle())
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selectedCount)
    }
}

// MARK: - Pill Press Style

/// Scale-down press feedback — replaces UIKit's default highlight rect.
private struct PillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Selection & Lifecycle

extension AnimatedPhotoPicker {
    func selectionOrder(for id: String) -> Int {
        (selectedIds.firstIndex(of: id) ?? -1) + 1
    }

    func toggleSelection(_ id: String) {
        Haptics.play(.light)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
            if let idx = selectedIds.firstIndex(of: id) {
                selectedIds.remove(at: idx)
            } else {
                selectedIds.append(id)
            }
        }
    }

    func confirmSelection() {
        Haptics.play(.medium)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pillScale = 0.9 }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6).delay(0.12)) { pillScale = 1.0 }
        let selected = selectedIds.compactMap { id in
            assets.first(where: { $0.id == id })?.asset
        }
        hidePanel { onConfirm(selected) }
    }

    func show() {
        // Dismiss the keyboard before the panel animates up so it covers the
        // full screen without the software keyboard pushing over it.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        selectedIds.removeAll()
        dragOffset = 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { isVisible = true }
    }

    func dismiss() {
        Haptics.play(.light)
        hidePanel { onDismiss() }
    }

    func hidePanel(completion: (() -> Void)? = nil) {
        withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) { isVisible = false }
        if let completion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { completion() }
        }
    }
}

// MARK: - Photo Loading

extension AnimatedPhotoPicker {
    func loadPhotos() async {
        // Already loaded — grid will appear instantly on re-open.
        if !assets.isEmpty {
            await MainActor.run { loading = false }
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            hasAccess = true
            await fetchAssets()
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            hasAccess = granted == .authorized || granted == .limited
            if hasAccess { await fetchAssets() }
        default:
            hasAccess = false
            await MainActor.run { loading = false }
        }
    }

    func fetchAssets() async {
        // Step 1: metadata fetch — fast, no image data
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: opts)

        var loaded: [PickerPhotoAsset] = []
        loaded.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            loaded.append(PickerPhotoAsset(id: asset.localIdentifier, asset: asset))
        }

        // Step 2: show grid immediately — no shimmer wait.
        // Cells render with a dark placeholder and fill in below.
        await MainActor.run {
            assets  = loaded
            loading = false
        }

        // Step 3: prime PHCachingImageManager for the first two visible screens
        // (~18 cells) so photos appear before the user starts scrolling.
        let firstBatch = Array(loaded.prefix(18)).map(\.asset)
        let targetSize = await MainActor.run { thumbSize }
        imageManager.allowsCachingHighQualityImages = false
        imageManager.startCachingImages(
            for: firstBatch,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: cachingOptions
        )

        // Step 4: load thumbnails in batches of 18 and push to the model.
        // Each cell already shows a placeholder while its thumbnail arrives.
        let batchSize = 18
        for i in stride(from: 0, to: loaded.count, by: batchSize) {
            let batch = Array(loaded[i..<min(i + batchSize, loaded.count)])
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for photo in batch {
                    group.addTask { (photo.id, await self.loadThumbnail(for: photo.asset)) }
                }
                for await (id, image) in group {
                    guard let image else { continue }
                    await MainActor.run {
                        if let idx = assets.firstIndex(where: { $0.id == id }) {
                            assets[idx].thumbnail = image
                        }
                    }
                }
            }
        }
    }

    func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            var resumed = false
            let opts = PHImageRequestOptions()
            // Use high-quality format for the batch pre-load so that thumbnails
            // stored in `assets[idx].thumbnail` are always sharp. This runs in the
            // background after the grid is already visible so performance is fine.
            opts.deliveryMode        = .highQualityFormat
            opts.resizeMode          = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous       = false

            imageManager.requestImage(
                for: asset,
                targetSize: thumbSize,
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed, let image else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
    }
}

// MARK: - System PHPickerViewController Wrapper

/// Wraps UIKit's PHPickerViewController so users can browse albums and
/// access their full photo library (not just Camera Roll recents).
private struct SystemPhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int
    var onPick: ([PHAsset]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter = .images
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHAsset]) -> Void
        init(onPick: @escaping ([PHAsset]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { onPick([]); return }
            // Map PHPickerResult → PHAsset via assetIdentifier
            let ids = results.compactMap(\.assetIdentifier)
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assets: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
            onPick(assets)
        }
    }
}

// MARK: - Photo Grid Cell
//
// Each cell owns its thumbnail state and requests it via PHCachingImageManager
// on .task — no polling the parent model. The caching manager's pre-warm ensures
// the image is already decoded when the task fires for visible cells.

private struct PhotoGridCell: View {
    let photo: PickerPhotoAsset
    let selectionOrder: Int         // 0 = unselected, 1+ = order badge
    let imageManager: PHCachingImageManager
    let targetSize: CGSize
    let onTap: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    private var isSelected: Bool { selectionOrder > 0 }

    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                ZStack(alignment: .bottomTrailing) {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()
                    } else {
                        // Dark placeholder — appears instantly, no spinner
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: geo.size.width, height: geo.size.width)
                    }

                    if isSelected { Color.black.opacity(0.18) }

                    badgeView.padding(5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
        }
        .buttonStyle(.plain)
        .task(id: photo.id) {
            // If the parent model already has a sharp thumbnail (re-open), use it.
            if let cached = photo.thumbnail { thumbnail = cached; return }
            startFetchingThumbnail()
        }
        .onDisappear {
            // Cancel the in-flight request when the cell scrolls off-screen
            // to avoid stale callbacks updating the wrong cell.
            if requestID != PHInvalidImageRequestID {
                imageManager.cancelImageRequest(requestID)
                requestID = PHInvalidImageRequestID
            }
        }
    }

    /// Starts a PHImageManager request that updates `thumbnail` on EVERY delivery.
    /// With `.opportunistic`, PHImageManager calls back twice:
    ///   1. A fast/degraded image — fills the cell immediately.
    ///   2. A full-resolution image — replaces the blurry one when ready.
    /// By NOT guarding on a `resumed` flag we let both deliveries update state,
    /// so the sharp image always wins and the cell never stays blurry.
    private func startFetchingThumbnail() {
        let opts = PHImageRequestOptions()
        opts.deliveryMode        = .opportunistic   // fast first, then sharp
        opts.resizeMode          = .fast
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous       = false

        requestID = imageManager.requestImage(
            for: photo.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: opts
        ) { [self] image, info in
            guard let image else { return }
            // PHImageResultIsDegradedKey == true means this is the fast/blurry
            // first delivery; false (or absent) means it's the final sharp image.
            // We accept both — the second delivery simply overwrites the first.
            DispatchQueue.main.async { thumbnail = image }
        }
    }

    private var badgeView: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.blue : Color.clear)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.clear : Color.white.opacity(0.75),
                            lineWidth: 1.5
                        )
                )

            if isSelected {
                Text("\(selectionOrder)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
        }
        .scaleEffect(isSelected ? 1.0 : 0.85)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isSelected)
        .animation(.spring(response: 0.2,  dampingFraction: 0.7),  value: selectionOrder)
    }
}

// MARK: - Shimmer Effect

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.3

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: phase - 0.2),
                        .init(color: .white.opacity(0.07), location: phase),
                        .init(color: .clear, location: phase + 0.2),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

private extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}
