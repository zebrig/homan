import SwiftUI

/// Shared card for any model backed by `DownloadableModel` (Gemma summary models
/// now, ASR/post-processor later). Shows Download / progress / Delete with a live
/// read of the external-process download state file, so progress survives app
/// restarts (e.g. the onboarding wizard's permission-step restart).
struct DownloadableModelCardView: View {
    let model: any DownloadableModel
    let downloadManager: ExternalProcessDownload?
    let isActive: Bool
    let onSetActive: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var isDownloading = false
    @State private var progress = 0.0
    @State private var statePollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        Text(model.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Text(model.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                statusBadge
            }

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading…")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            actionButtons
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
        .onAppear {
            refreshState()
            // If a download is mid-flight (e.g. resumed after a wizard step change
            // or app restart), resume polling — otherwise the card would show a
            // stale "Downloading" forever and never notice completion.
            if isDownloading || downloadManager?.currentState?.status == .downloading {
                startPolling()
            }
        }
        .onDisappear { statePollTask?.cancel() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isActive {
            Text("Active")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.success.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if isDownloading {
            Text("Downloading")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if model.isDownloaded {
            Text("Downloaded")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if isDownloading {
                Button("Cancel") {
                    downloadManager?.cancel()
                    isDownloading = false
                    progress = 0
                    statePollTask?.cancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            } else if model.isDownloaded {
                if !isActive, let onSetActive {
                    Button("Set Active") {
                        onSetActive()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                if let onDelete {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Download") {
                    startDownload()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
    }

    private func startDownload() {
        guard let downloadManager else { return }
        do {
            try downloadManager.start()
        } catch {
            fputs("[muesli-native] model download launch failed: \(error)\n", stderr)
            return
        }
        isDownloading = true
        progress = 0
        startPolling()
    }

    /// Poll the external-process download state file until it reaches a terminal
    /// state. Called on Download and re-called on appear so progress keeps
    /// updating after step changes / app restarts.
    private func startPolling() {
        statePollTask?.cancel()
        statePollTask = Task {
            while !Task.isCancelled {
                refreshState()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refreshState() {
        guard let state = downloadManager?.currentState else {
            isDownloading = false
            return
        }
        switch state.status {
        case .downloading:
            isDownloading = true
            let total = state.total ?? 1
            progress = total > 0 ? min(Double(state.bytes) / Double(total), 1) : 0
        case .done:
            isDownloading = false
            progress = 1
            statePollTask?.cancel()
        case .error:
            isDownloading = false
            progress = 0
            statePollTask?.cancel()
            fputs("[muesli-native] model download error: \(state.error ?? "unknown")\n", stderr)
        }
    }
}
