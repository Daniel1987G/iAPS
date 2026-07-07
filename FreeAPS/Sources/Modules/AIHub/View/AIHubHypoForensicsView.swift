import SwiftUI

/// Hypo-Forensik: Überblick, Ursachen-Verteilung und Episoden-Liste rechnen
/// lokal und sofort; die KI-Einordnung läuft auf Knopfdruck und wird pro
/// Tag gecacht.
struct AIHubHypoForensicsView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var days = 30
    @State private var result: AIHubHypoForensics.Result?
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

                summaryCard
                causesCard
                insightsLink
                episodesCard
                narrativeCard
                disclaimer
            }
            .padding(16)
        }
        .background(
            Color(colorScheme == .dark ? .systemBackground : .secondarySystemBackground)
                .ignoresSafeArea()
        )
        .navigationTitle(hubT("hf.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: days) { _ in reload() }
    }

    // MARK: - Laden

    private func reload() {
        result = nil
        narrative = AIHubHypoForensics.cachedNarrative(days: days)
        errorText = nil
        let period = days
        Task { @MainActor in
            result = await Task.detached(priority: .userInitiated) {
                AIHubHypoForensics.analyze(days: period)
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
                let prompt = AIHubHypoForensics.narrativePrompt(for: result)
                let text = try await AIHubChatService.executePrompt(prompt)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                narrative = text
                AIHubHypoForensics.storeNarrative(text, days: period)
            } catch {
                errorText = error.localizedDescription
            }
            isGenerating = false
        }
    }

    // MARK: - Überblick

    @ViewBuilder private var summaryCard: some View {
        if let result = result {
            if result.readingCount < 100 {
                card {
                    Text(hubT("hf.toolittle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if result.episodes.isEmpty {
                card {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(hubT("hf.none"))
                            .font(.subheadline)
                    }
                }
            } else {
                card {
                    VStack(spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(result.episodes.count)")
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                Text(hubT("hf.count.caption", result.days))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let previous = result.previousCount {
                                Text(hubT("hf.vs.prev", previous))
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(
                                            (result.episodes.count <= previous ? Color.green : Color.orange)
                                                .opacity(0.15)
                                        )
                                    )
                                    .foregroundStyle(
                                        result.episodes.count <= previous ? Color.green : Color.orange
                                    )
                            }
                        }
                        Divider()
                        HStack {
                            metricCell(
                                title: hubT("hf.mean.low"),
                                value: AIHubTherapyAnalysis.formatGlucose(result.meanMinMgdl, isMmol: result.isMmol)
                            )
                            metricCell(
                                title: hubT("hf.mean.duration"),
                                value: hubT("hf.min.format", result.meanDurationMinutes)
                            )
                            metricCell(
                                title: hubT("hf.night"),
                                value: String(format: "%.0f %%", result.nocturnalShare * 100)
                            )
                        }
                    }
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

    private func metricCell(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ursachen

    @ViewBuilder private var causesCard: some View {
        if let result = result, !result.episodes.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(hubT("hf.causes.title"))
                        .font(.headline)
                    ForEach(sortedCauses(result), id: \.cause) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(entry.total)×")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(tint(for: entry.cause))
                                .frame(width: 36, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.cause.label)
                                    .font(.subheadline.weight(.semibold))
                                Text(entry.cause.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // Tupel-Feld heißt bewusst `total`, nicht `count` — SwiftFormats
    // isEmpty-Regel schreibt `.count > 0` sonst zu `!.isEmpty` um und
    // bricht den Build (Int hat kein isEmpty).
    private func sortedCauses(_ result: AIHubHypoForensics.Result)
        -> [(cause: AIHubHypoForensics.Cause, total: Int)]
    {
        AIHubHypoForensics.Cause.allCases
            .map { (cause: $0, total: result.count(of: $0)) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
    }

    private func tint(for cause: AIHubHypoForensics.Cause) -> Color {
        switch cause {
        case .meal: return .orange
        case .overcorrection: return .red
        case .stacking: return .purple
        case .basal: return .blue
        case .unknown: return .secondary
        }
    }

    // MARK: - Absprung zu Therapy Insights

    /// Basal- und Mahlzeiten-Hypos sind über Profil-Slots behebbar — wenn
    /// sie dominieren, direkt zur Werkbank verlinken (wie im Recap).
    @ViewBuilder private var insightsLink: some View {
        if let result = result, !result.episodes.isEmpty,
           (result.count(of: .basal) + result.count(of: .meal)) * 2 >= result.episodes.count
        {
            NavigationLink(destination: AIHubTherapyInsightsView()) {
                card {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.blue)
                        Text(hubT("recap.checkinsights"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Episoden-Liste

    @ViewBuilder private var episodesCard: some View {
        if let result = result, !result.episodes.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hubT("hf.list.title"))
                        .font(.headline)
                    ForEach(result.episodes.prefix(8)) { episode in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(tint(for: episode.cause))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(Self.dateFormatter.string(from: episode.start))
                                        .font(.subheadline.weight(.medium))
                                    if episode.isNocturnal {
                                        Image(systemName: "moon.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.indigo)
                                    }
                                }
                                Text(hubT(
                                    "hf.list.detail",
                                    AIHubTherapyAnalysis.formatGlucose(
                                        Double(episode.minMgdl),
                                        isMmol: result.isMmol
                                    ),
                                    episode.durationMinutes
                                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(episode.cause.label)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(tint(for: episode.cause).opacity(0.15)))
                                .foregroundStyle(tint(for: episode.cause))
                        }
                    }
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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
                    Text(hubT("hf.nokey"))
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
                    .disabled(result?.episodes.isEmpty != false)
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
        Text(hubT("hf.disclaimer"))
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
