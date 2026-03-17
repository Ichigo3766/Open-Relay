import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers

// MARK: - Unified Attachment Picker

/// A consolidated attachment picker that shows recent photos in a scrollable grid
/// along with quick-action buttons for Camera, Document, and All Photos.
///
/// Replaces the fragmented flow of separate PhotosPicker and file picker buttons
/// with a single, beautiful bottom sheet that covers all attachment types.
struct UnifiedAttachmentPicker: View {
    let onPhotoSelected: ([PhotosPickerItem]) -> Void
    let onFileSelected: ([URL]) -> Void
    let onDismiss: () -> Void
    
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    
    @State private var recentPhotos: [PHAsset] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFullPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var hasPhotoAccess = false
    @State private var loadingPhotos = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 12)
            
            // Title
            HStack {
                Text("Add Attachment")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 22)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.bottom, 14)
            
            // Recent Photos Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                    Text("Recent Photos")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    
                    // Full photo picker via PhotosPicker
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .images
                    ) {
                        HStack(spacing: 3) {
                            Text("See All")
                                .scaledFont(size: 12, weight: .medium)
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 10, weight: .semibold)
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.screenPadding)
                
                if loadingPhotos {
                    // Loading skeleton
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(theme.surfaceContainer)
                                    .frame(width: 80, height: 80)
                            }
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                    }
                } else if hasPhotoAccess && !recentPhotos.isEmpty {
                    // Photo grid
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(recentPhotos.prefix(20).enumerated()), id: \.offset) { _, asset in
                                RecentPhotoThumbnail(asset: asset) { selectedAsset in
                                    handlePhotoAssetSelected(selectedAsset)
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                    }
                } else {
                    // No access or no photos
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .scaledFont(size: 24)
                                .foregroundStyle(theme.textTertiary)
                            Text(hasPhotoAccess ? "No photos found" : "Grant photo access to browse")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                }
            }
            .padding(.bottom, 16)
            
            // Divider
            Divider()
                .padding(.horizontal, Spacing.screenPadding)
            
            // Quick Actions
            VStack(spacing: 2) {
                // Document picker
                actionButton(
                    icon: "doc",
                    title: "Document",
                    subtitle: "PDF, Word, Excel, and more",
                    color: theme.brandPrimary
                ) {
                    showDocumentPicker = true
                }
                
                // Photo library (fallback for no-permission)
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    actionRow(
                        icon: "photo.stack",
                        title: "Photo Library",
                        subtitle: "Browse all photos and videos",
                        color: Color(hex: 0x10B981)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.bottom, 20)
        }
        .background(theme.isDark ? theme.cardBackground : theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task {
            await loadRecentPhotos()
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            onPhotoSelected(items)
            selectedPhotoItems = []
            onDismiss()
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                onFileSelected(urls)
                onDismiss()
            }
        }
    }
    
    // MARK: - Action Button
    
    private func actionButton(icon: String, title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionRow(icon: icon, title: title, subtitle: subtitle, color: color)
        }
        .buttonStyle(.plain)
    }
    
    private func actionRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .scaledFont(size: 17, weight: .medium)
                    .foregroundStyle(color)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
    
    // MARK: - Photo Loading
    
    private func loadRecentPhotos() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            hasPhotoAccess = true
            await fetchRecentPhotos()
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            hasPhotoAccess = newStatus == .authorized || newStatus == .limited
            if hasPhotoAccess {
                await fetchRecentPhotos()
            }
        default:
            hasPhotoAccess = false
        }
        
        loadingPhotos = false
    }
    
    private func fetchRecentPhotos() async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 30
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        
        let results = PHAsset.fetchAssets(with: fetchOptions)
        var assets: [PHAsset] = []
        results.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        
        await MainActor.run {
            recentPhotos = assets
        }
    }
    
    private func handlePhotoAssetSelected(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data else { return }
            let image = UIImage(data: data)
            let resized = FileAttachmentService.downsampleForUpload(data: data, image: image)
            
            DispatchQueue.main.async {
                // Write to temp file as an image so processFileURL handles it correctly
                let fileName = "Photo_\(Int(Date.now.timeIntervalSince1970)).jpg"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try? resized.write(to: tempURL)
                self.onFileSelected([tempURL])
                // Dismiss AFTER passing the files — give time for state to propagate
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.onDismiss()
                }
            }
        }
    }
}

// MARK: - Recent Photo Thumbnail

/// Displays a single photo from the user's library as a tappable thumbnail.
private struct RecentPhotoThumbnail: View {
    let asset: PHAsset
    let onSelect: (PHAsset) -> Void
    
    @State private var thumbnail: UIImage?
    @Environment(\.theme) private var theme
    
    var body: some View {
        Button {
            Haptics.play(.light)
            onSelect(asset)
        } label: {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.surfaceContainer)
                        .frame(width: 80, height: 80)
                        .overlay(
                            ProgressView().controlSize(.small)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        
        let targetSize = CGSize(width: 160, height: 160) // 2x for retina
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }
}
