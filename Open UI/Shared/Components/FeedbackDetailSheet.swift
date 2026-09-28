import SwiftUI

// MARK: - Feedback Detail Sheet

struct FeedbackDetailSheet: View {
    let message: ChatMessage
    @Bindable var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var detailRating: Int = 0  // 0 = uninitialised; set in .task
    @State private var selectedReason: String? = nil
    @State private var comment: String = ""
    @State private var tags: [String] = []
    @State private var tagInput: String = ""
    @State private var isLoadingTags: Bool = false
    @State private var isSaving: Bool = false

    private let positiveReasons: [(String, String)] = [
        ("accurate_information", "Accurate information"),
        ("followed_instructions_perfectly", "Followed instructions perfectly"),
        ("showcased_creativity", "Showcased creativity"),
        ("positive_attitude", "Positive attitude"),
        ("attention_to_detail", "Attention to detail"),
        ("thorough_explanation", "Thorough explanation"),
        ("other", "Other")
    ]
    private let negativeReasons: [(String, String)] = [
        ("incorrect_information", "Incorrect information"),
        ("refused_to_follow_instructions", "Refused to follow instructions"),
        ("not_creative_enough", "Not creative enough"),
        ("negative_attitude", "Negative attitude"),
        ("missing_info", "Missing info"),
        ("other", "Other")
    ]

    var isPositive: Bool { (message.annotation?.rating ?? 1) > 0 }
    var reasons: [(String, String)] { isPositive ? positiveReasons : negativeReasons }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: Numeric rating scale (6–10 for thumbs up, 1–5 for thumbs down)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("How would you rate this response?")
                            .font(.headline)
                        HStack(spacing: 4) {
                            ForEach(isPositive ? 6...10 : 1...5, id: \.self) { n in
                                Button {
                                    detailRating = n
                                } label: {
                                    Text("\(n)")
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(width: 30, height: 30)
                                        .background(detailRating == n ? Color.accentColor : Color(.systemGray5))
                                        .foregroundColor(detailRating == n ? .white : .primary)
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            Text(isPositive ? "6 - Good" : "1 - Awful").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(isPositive ? "10 - Amazing" : "5 - Poor").font(.caption).foregroundColor(.secondary)
                        }
                    }

                    // MARK: Why? chip grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Why?")
                            .font(.headline)
                        FeedbackFlowLayout(spacing: 8) {
                            ForEach(reasons, id: \.0) { key, label in
                                Button {
                                    selectedReason = selectedReason == key ? nil : key
                                } label: {
                                    Text(label)
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(selectedReason == key ? Color.accentColor : Color(.systemGray5))
                                        .foregroundColor(selectedReason == key ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // MARK: Free-text comment
                    TextField("Feel free to add specific details", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                    // MARK: Tags row
                    VStack(alignment: .leading, spacing: 8) {
                        if isLoadingTags {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } else {
                            FeedbackFlowLayout(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.subheadline)
                                        Button {
                                            tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                                }
                                // Inline tag input field as a chip
                                HStack(spacing: 4) {
                                    TextField("Add a tag...", text: $tagInput)
                                        .font(.subheadline)
                                        .frame(minWidth: 80)
                                        .onSubmit { addTag() }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("Rate Response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        Task { await save() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(isSaving)
                    .overlay {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
            }
        }
        .task {
            // Determine valid range based on thumbs direction
            let validRange = isPositive ? (6...10) : (1...5)
            let defaultRating = isPositive ? 8 : 3
            // Pre-populate from existing annotation if present
            if let ann = message.annotation {
                let saved = ann.detailRating ?? defaultRating
                // Clamp to valid range in case the rating was set before this constraint was added
                detailRating = validRange.contains(saved) ? saved : defaultRating
                selectedReason = ann.reason
                comment = ann.comment ?? ""
                tags = ann.tags
            } else {
                detailRating = defaultRating
            }
            // Load AI-suggested tags if none set yet
            if tags.isEmpty {
                isLoadingTags = true
                tags = await viewModel.loadTagSuggestions(for: message)
                isLoadingTags = false
            }
        }
    }

    // MARK: Helpers

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { tagInput = ""; return }
        tags.append(trimmed)
        tagInput = ""
    }

    private func save() async {
        isSaving = true
        await viewModel.saveFeedbackDetails(
            message: message,
            detailRating: detailRating,
            reason: selectedReason,
            comment: comment,
            tags: tags
        )
        isSaving = false
        dismiss()
    }
}

// MARK: - Flow Layout for Chip Grids

/// Simple wrapping flow layout used for the "Why?" chip grid and tags row.
/// Named `FeedbackFlowLayout` to avoid conflicts with other layouts in the project.
struct FeedbackFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        flowLayout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = flowLayout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func flowLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
