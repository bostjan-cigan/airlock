import AirlockControl
import AirlockCore
import AirlockEngine
import SwiftUI

/// What handing a task off brings out. The same review whether the user clicked Hand Off or a
/// Claude chat asked (then it's in an approval prompt).
struct HandoffReviewContent: View {
    let review: HandoffReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group {
                row("Commits", "\(review.commits.count)")
                row("Files changed", "\(review.files)", trailing: "+\(review.additions) −\(review.deletions)")
                if let setup = review.setup {
                    row("Setup", setup, alarm: review.setupFindings > 0)
                }
            }
            if !review.attention.isEmpty {
                Text("Look at these before you merge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                group {
                    ForEach(review.attention, id: \.path) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.reason).font(.callout).foregroundStyle(.orange)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            if let n = review.uncommitted, n > 0 {
                Label("\(n) uncommitted file\(n == 1 ? "" : "s") stay\(n == 1 ? "s" : "") behind", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    func row(_ label: String, _ value: String, trailing: String? = nil, alarm: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(alarm ? .red : .secondary).lineLimit(2).multilineTextAlignment(.trailing)
            if let trailing { Text(trailing).foregroundStyle(.tertiary) }
        }
        .font(.callout)
        .padding(.vertical, 6)
    }
}

/// The user hands a task off from the app: the review, then Hand Off.
struct HandoffSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var review: HandoffReview?
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        let task = model.tasks[taskID]
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Hand off “\(task?.title ?? "this task")”?")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(task?.repo.isPlainFolder == true
                 ? "Its work is applied to the files in \(task?.repo.name ?? "the folder"). Nothing else leaves the container."
                 : "Its branch \(task?.workspace.branch ?? "") appears in your repository. Nothing else leaves the container.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let review {
                if review.nothingNew {
                    Text("Nothing new: the branch is in your repository as it is.").font(.callout)
                } else {
                    HandoffReviewContent(review: review)
                }
            } else if problem == nil {
                ProgressView().controlSize(.small)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { dismiss() } label: { Text("Not Now").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        do {
                            try await model.engine.handOff(taskID)
                            dismiss()
                        } catch {
                            problem = String(describing: error)
                            working = false
                        }
                    }
                } label: {
                    Text("Hand Off").frame(maxWidth: .infinity)
                }
                .disabled(review == nil || review?.nothingNew == true || working)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 420)
        .task {
            do { review = try await model.engine.handoffReview(taskID) } catch { problem = String(describing: error) }
        }
    }
}
