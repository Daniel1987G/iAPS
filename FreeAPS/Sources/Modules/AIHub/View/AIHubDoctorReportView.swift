import SwiftUI

/// Arztbericht: Vorschau der Kennzahlen rechnet lokal und sofort; die
/// optionale KI-Zusammenfassung läuft auf Knopfdruck (pro Tag gecacht) und
/// wird — falls vorhanden — ins PDF übernommen. „PDF erstellen & teilen"
/// rendert A4-Seiten und öffnet das System-Share-Sheet.
struct AIHubDoctorReportView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var days = 90
    @State private var report: AIHubDoctorReport.ReportData?
    @State private var loaded = false
    @State private var narrative: String?
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var shareURL: URL?
    @State private var isRendering = false

    private let intervals = [30, 90]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("", selection: $days) {
                    ForEach(intervals, id: \.self) { interval in
                        Text(hubT("ti.days.format", interval)).tag(interval)
                    }
                }
                .pickerStyle(.segmented)

                previewCard
                narrativeCard
                shareCard
                disclaimer
            }
            .padding(16)
        }
        .background(
            Color(colorScheme == .dark ? .systemBackground : .secondarySystemBackground)
                .ignoresSafeArea()
        )
        .navigationTitle(hubT("dr.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: days) { _ in reload() }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - Laden

    private func reload() {
        report = nil
        loaded = false
        narrative = AIHubDoctorReport.cachedNarrative(days: days)
        errorText = nil
        let period = days
        Task { @MainActor in
            report = await Task.detached(priority: .userInitiated) {
                AIHubDoctorReport.build(days: period)
            }.value
            loaded = true
        }
    }

    private func generateNarrative() {
        guard let report = report, !isGenerating else { return }
        isGenerating = true
        errorText = nil
        let period = days
        Task { @MainActor in
            do {
                let prompt = AIHubDoctorReport.narrativePrompt(for: report)
                let text = try await AIHubChatService.executePrompt(prompt)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                narrative = text
                AIHubDoctorReport.storeNarrative(text, days: period)
            } catch {
                errorText = error.localizedDescription
            }
            isGenerating = false
        }
    }

    /// HTML → WebKit-PDF (asynchron, Main-Thread), dann Share-Sheet.
    private func createAndShare() {
        guard let report = report, !isRendering else { return }
        isRendering = true
        errorText = nil
        let html = AIHubDoctorReport.html(for: report, aiSummary: narrative)
        AIHubPDFRenderer.shared.render(html: html) { data in
            isRendering = false
            guard let data = data,
                  let url = AIHubDoctorReport.writePDF(data, generatedAt: report.generatedAt)
            else {
                errorText = "PDF error"
                return
            }
            shareURL = url
        }
    }

    // MARK: - Vorschau

    @ViewBuilder private var previewCard: some View {
        if let report = report {
            card {
                VStack(spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f %%", report.inRange * 100))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                            Text(hubT("dr.tir.inrange"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f %%", report.gmi))
                                .font(.title3.bold())
                            Text(hubT("dr.l.gmi"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    tirBar(report)

                    Divider()
                    HStack {
                        metricCell(
                            title: hubT("dr.l.mean"),
                            value: AIHubTherapyAnalysis.formatGlucose(report.meanMgdl, isMmol: report.isMmol)
                        )
                        metricCell(title: "CV", value: String(format: "%.0f %%", report.cv * 100))
                        metricCell(title: hubT("dr.l.episodes"), value: "\(report.hypoCount)")
                        metricCell(
                            title: hubT("dr.l.coverage"),
                            value: String(format: "%.0f %%", report.coverage * 100)
                        )
                    }
                }
            }
        } else if loaded {
            card {
                Text(hubT("hf.toolittle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    /// Gestapelter Zeit-in-Bereichen-Balken (Konsens-Farben).
    private func tirBar(_ report: AIHubDoctorReport.ReportData) -> some View {
        let buckets: [(share: Double, color: Color)] = [
            (report.veryLow, Color(red: 0.56, green: 0.11, blue: 0.11)),
            (report.low, Color(red: 0.84, green: 0.27, blue: 0.27)),
            (report.inRange, Color(red: 0.23, green: 0.65, blue: 0.33)),
            (report.high, Color(red: 0.91, green: 0.64, blue: 0.24)),
            (report.veryHigh, Color(red: 0.85, green: 0.49, blue: 0.07))
        ]
        return GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    if bucket.share > 0.001 {
                        Rectangle()
                            .fill(bucket.color)
                            .frame(width: max(3, geometry.size.width * bucket.share))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 14)
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - KI-Zusammenfassung

    private var narrativeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text(hubT("dr.h.ai.short"))
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
                    Label(hubT("dr.ai.include"), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if isGenerating {
                    HStack {
                        ProgressView()
                        Text(hubT("audit.ai.generating"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if !AIHubChatService.isConfigured {
                    Text(hubT("dr.nokey"))
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
                    .disabled(report == nil)
                }

                if let error = errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - PDF & Teilen

    private var shareCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    createAndShare()
                } label: {
                    Group {
                        if isRendering {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label(hubT("dr.share"), systemImage: "square.and.arrow.up")
                        }
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.cyan))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(report == nil || isRendering)

                Text(hubT("dr.share.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bausteine

    private var disclaimer: some View {
        Text(hubT("dr.footer"))
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
