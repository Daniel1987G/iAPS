import SwiftUI

/// Loop Check: Settings-Audit. Die Checks rechnen lokal und sofort;
/// die KI-Einordnung läuft auf Knopfdruck und wird pro Tag gecacht.
struct AIHubSettingsAuditView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var days = 30
    @State private var result: AIHubSettingsAudit.Result?
    @State private var narrative: String?
    @State private var isGenerating = false
    @State private var errorText: String?

    private let intervals = [14, 30, 90]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("", selection: $days) {
                    ForEach(intervals, id: \.self) { interval in
                        Text(hubT("ti.days.format", interval)).tag(interval)
                    }
                }
                .pickerStyle(.segmented)

                findingsCards
                narrativeCard
                disclaimer
            }
            .padding(16)
        }
        .background(
            Color(colorScheme == .dark ? .systemBackground : .secondarySystemBackground)
                .ignoresSafeArea()
        )
        .navigationTitle("Loop Check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: days) { _ in reload() }
    }

    // MARK: - Laden

    private func reload() {
        result = nil
        narrative = AIHubSettingsAudit.cachedNarrative(days: days)
        errorText = nil
        let period = days
        Task { @MainActor in
            result = await Task.detached(priority: .userInitiated) {
                AIHubSettingsAudit.analyze(days: period)
            }.value
        }
    }

    private func generateNarrative() {
        guard let result = result, !isGenerating else { return }
        isGenerating = true
        errorText = nil
        let period = days
        Task { @MainActor in
            do {
                let prompt = AIHubSettingsAudit.narrativePrompt(for: result)
                let text = try await AIHubChatService.executePrompt(prompt)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                narrative = text
                AIHubSettingsAudit.storeNarrative(text, days: period)
            } catch {
                errorText = error.localizedDescription
            }
            isGenerating = false
        }
    }

    // MARK: - Befunde

    @ViewBuilder private var findingsCards: some View {
        if let result = result {
            if result.findings.isEmpty {
                card {
                    Text(hubT("audit.toolittle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(result.findings) { finding in
                    findingCard(finding)
                }
            }
        } else {
            card {
                HStack {
                    ProgressView()
                    Text(hubT("recap.computing")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func findingCard(_ finding: AIHubSettingsAudit.Finding) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: finding.severity))
                        .foregroundStyle(tint(for: finding.severity))
                    Text(finding.title)
                        .font(.headline)
                    Spacer()
                    Text(label(for: finding.severity))
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint(for: finding.severity).opacity(0.15)))
                        .foregroundStyle(tint(for: finding.severity))
                }
                Text(finding.detail)
                    .font(.subheadline)
                    .foregroundStyle(finding.severity == .ok ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(for severity: AIHubSettingsAudit.Severity) -> String {
        switch severity {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for severity: AIHubSettingsAudit.Severity) -> Color {
        switch severity {
        case .ok: return .green
        case .info: return .blue
        case .warn: return .orange
        }
    }

    private func label(for severity: AIHubSettingsAudit.Severity) -> String {
        switch severity {
        case .ok: return hubT("audit.sev.ok")
        case .info: return hubT("audit.sev.info")
        case .warn: return hubT("audit.sev.warn")
        }
    }

    // MARK: - KI-Einordnung

    private var narrativeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text(hubT("audit.ai.title"))
                        .font(.headline)
                    Spacer()
                    if narrative != nil, !isGenerating {
                        Button {
                            generateNarrative()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let narrative = narrative {
                    Text(narrative)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isGenerating {
                    HStack {
                        ProgressView()
                        Text(hubT("audit.ai.generating"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if !AIHubChatService.isConfigured {
                    Text(hubT("audit.nokey"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        generateNarrative()
                    } label: {
                        Text(hubT("audit.ai.generate"))
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.purple.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled(result?.findings.isEmpty != false)
                }

                if let error = errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Bausteine

    private var disclaimer: some View {
        Text(hubT("audit.disclaimer"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(colorScheme == .dark ? .secondarySystemBackground : .systemBackground))
        )
    }
}
