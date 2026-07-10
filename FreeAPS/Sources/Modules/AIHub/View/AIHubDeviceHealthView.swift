import SwiftUI

/// Hardware-Check: Sensor- & Patch-Status, getrennte Setzstellen-Rotation
/// (zwei Körper-Grafiken nebeneinander: Patch mint, Sensor blau),
/// nächtliche Kompressions-Lows und Sensor-Rauschen. Analyse rechnet
/// lokal und sofort; KI-Einordnung auf Knopfdruck (pro Tag gecacht).
struct AIHubDeviceHealthView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var days = 30
    @State private var result: AIHubDeviceHealth.Result?
    @State private var narrative: String?
    @State private var isGenerating = false
    @State private var errorText: String?

    // Rotation — getrennte Kreise für Patch und Sensor
    @State private var enabledPatch = AIHubDeviceHealth.enabledSites(for: .patch)
    @State private var enabledSensor = AIHubDeviceHealth.enabledSites(for: .sensor)
    @State private var editMode = false
    @State private var justAssigned: (kind: AIHubDeviceHealth.DeviceKind, site: AIHubDeviceHealth.Site)?

    private let intervals = [30, 90]

    private let patchTint = Color.mint
    private let sensorTint = Color.blue

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("", selection: $days) {
                    ForEach(intervals, id: \.self) { interval in
                        Text(hubT("ti.days.format", interval)).tag(interval)
                    }
                }
                .pickerStyle(.segmented)

                statusCard
                rotationCard
                compressionCard
                noiseCard
                narrativeCard
                disclaimer
            }
            .padding(16)
        }
        .background(
            Color(colorScheme == .dark ? .systemBackground : .secondarySystemBackground)
                .ignoresSafeArea()
        )
        .navigationTitle(hubT("dh.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: days) { _ in reload() }
    }

    // MARK: - Laden

    private func reload() {
        result = nil
        narrative = AIHubDeviceHealth.cachedNarrative(days: days)
        errorText = nil
        justAssigned = nil
        let period = days
        Task { @MainActor in
            result = await Task.detached(priority: .userInitiated) {
                AIHubDeviceHealth.analyze(days: period)
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
                let prompt = AIHubDeviceHealth.narrativePrompt(for: result)
                let text = try await AIHubChatService.executePrompt(prompt)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                narrative = text
                AIHubDeviceHealth.storeNarrative(text, days: period)
            } catch {
                errorText = error.localizedDescription
            }
            isGenerating = false
        }
    }

    // MARK: - Status (aktueller Patch & Sensor)

    @ViewBuilder private var statusCard: some View {
        if let result = result {
            card {
                HStack {
                    statusCell(
                        icon: "bandage.fill",
                        tint: patchTint,
                        title: hubT("dh.patch"),
                        startedAt: result.patchActivatedAt
                    )
                    Divider().frame(height: 44)
                    statusCell(
                        icon: "sensor.tag.radiowaves.forward.fill",
                        tint: sensorTint,
                        title: hubT("dh.sensor"),
                        startedAt: result.sensorStartedAt
                    )
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

    private func statusCell(icon: String, tint: Color, title: String, startedAt: Date?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                if let startedAt = startedAt {
                    let day = Int(Date().timeIntervalSince(startedAt) / 86400) + 1
                    Text(hubT("dh.day.format", day))
                        .font(.subheadline.bold())
                    Text(Self.shortFormatter.string(from: startedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").font(.subheadline.bold())
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Setzstellen-Rotation (zwei Figuren: Patch & Sensor)

    @ViewBuilder private var rotationCard: some View {
        if let result = result {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(hubT("dh.rotation.title"))
                            .font(.headline)
                        Spacer()
                        Button {
                            editMode.toggle()
                        } label: {
                            Text(editMode ? hubT("dh.rotation.done") : hubT("dh.rotation.edit"))
                                .font(.caption.bold())
                        }
                    }

                    if editMode {
                        Text(hubT("dh.rotation.setup"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if enabledPatch.isEmpty, enabledSensor.isEmpty {
                        Text(hubT("dh.rotation.none"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        rotationColumn(
                            kind: .patch,
                            icon: "bandage.fill",
                            title: hubT("dh.patch"),
                            tint: patchTint,
                            enabled: enabledPatch,
                            lastUsed: result.lastSite,
                            suggestion: result.suggestion,
                            pending: result.pendingChange
                        )
                        rotationColumn(
                            kind: .sensor,
                            icon: "sensor.tag.radiowaves.forward.fill",
                            title: hubT("dh.sensor"),
                            tint: sensorTint,
                            enabled: enabledSensor,
                            lastUsed: result.sensorLastSite,
                            suggestion: result.sensorSuggestion,
                            pending: result.sensorPending
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private func rotationColumn(
        kind: AIHubDeviceHealth.DeviceKind,
        icon: String,
        title: String,
        tint: Color,
        enabled: Set<AIHubDeviceHealth.Site>,
        lastUsed: AIHubDeviceHealth.Site?,
        suggestion: AIHubDeviceHealth.Site?,
        pending: AIHubDeviceHealth.PatchEvent?
    ) -> some View {
        VStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(tint)

            BodySiteView(
                enabled: enabled,
                lastUsed: lastUsed,
                suggestion: editMode ? nil : suggestion,
                editMode: editMode,
                tint: tint
            ) { site in
                handleTap(kind: kind, site: site)
            }
            .frame(height: 230)
            .frame(maxWidth: .infinity)

            // Offener Wechsel / gerade eingetragen / Legende
            if !editMode {
                if let assigned = justAssigned, assigned.kind == kind {
                    Label(hubT("dh.rotation.assigned", assigned.site.label), systemImage: "checkmark.circle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                } else if pending != nil, !enabled.isEmpty {
                    Label(hubT("dh.rotation.pending"), systemImage: "hand.tap.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                if let last = lastUsed {
                    legend(color: .orange, text: hubT("dh.rotation.last", last.label))
                }
                if let suggestion = suggestion {
                    legend(color: .green, text: hubT("dh.rotation.suggest", suggestion.label))
                } else if enabled.count == 1 {
                    // Rotation braucht mindestens zwei Stellen.
                    Text(hubT("dh.rotation.more"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func handleTap(kind: AIHubDeviceHealth.DeviceKind, site: AIHubDeviceHealth.Site) {
        if editMode {
            var sites = kind == .patch ? enabledPatch : enabledSensor
            if sites.contains(site) {
                sites.remove(site)
            } else {
                sites.insert(site)
            }
            AIHubDeviceHealth.setEnabledSites(sites, for: kind)
            if kind == .patch { enabledPatch = sites } else { enabledSensor = sites }
            return
        }
        // Zuordnungs-Modus: offener Wechsel bekommt die angetippte Stelle
        let pending = kind == .patch ? result?.pendingChange : result?.sensorPending
        let enabled = kind == .patch ? enabledPatch : enabledSensor
        guard let pending = pending, enabled.contains(site) else { return }
        AIHubDeviceHealth.assignSite(site, to: pending.activatedAt, kind: kind)
        justAssigned = (kind, site)
        // Log neu laden, damit „Zuletzt/Vorschlag" sofort stimmen
        let period = days
        Task { @MainActor in
            result = await Task.detached(priority: .userInitiated) {
                AIHubDeviceHealth.analyze(days: period)
            }.value
        }
    }

    // MARK: - Kompressions-Lows

    @ViewBuilder private var compressionCard: some View {
        if let result = result, result.readingCount >= 100 {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hubT("dh.comp.title"))
                        .font(.headline)
                    if result.compressionEvents.isEmpty {
                        Label(hubT("dh.comp.none"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    } else {
                        Text(hubT(
                            "dh.comp.found",
                            result.compressionEvents.count,
                            result.nightHypoCount
                        ))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(result.compressionEvents.prefix(4)) { event in
                            HStack(spacing: 8) {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.caption)
                                    .foregroundStyle(.indigo)
                                Text(Self.shortFormatter.string(from: event.date))
                                    .font(.caption)
                                Spacer()
                                Text(hubT(
                                    "dh.comp.detail",
                                    AIHubTherapyAnalysis.formatGlucose(
                                        Double(event.minMgdl),
                                        isMmol: result.isMmol
                                    ),
                                    event.recoveryMinutes
                                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(hubT("dh.comp.hint"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Sensor-Rauschen

    @ViewBuilder private var noiseCard: some View {
        if let result = result, result.readingCount >= 100 {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hubT("dh.noise.title"))
                        .font(.headline)
                    Text(hubT("dh.noise.jumps", String(format: "%.1f", result.jumpsPerDayOverall)))
                        .font(.subheadline)

                    if !result.noiseByDay.isEmpty {
                        // Mini-Balken: Sprünge/Tag über die Sensor-Laufzeit
                        let maxValue = max(result.noiseByDay.map(\.jumpsPerDay).max() ?? 1, 1)
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(result.noiseByDay) { entry in
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(entry.jumpsPerDay > maxValue * 0.66 ? Color.orange : Color.mint)
                                        .frame(height: max(4, 48 * entry.jumpsPerDay / maxValue))
                                    Text("\(entry.day)")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(height: 64, alignment: .bottom)
                    }

                    if result.noiseRisesLate {
                        Label(hubT("dh.noise.rising"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if result.firstDayNoisy {
                        Label(hubT("dh.noise.firstday"), systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    if !result.noiseRisesLate, !result.firstDayNoisy {
                        Label(hubT("dh.noise.ok"), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
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
                    .disabled(result == nil)
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
        Text(hubT("dh.disclaimer"))
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

// MARK: - Körper-Grafik mit Setzstellen

/// Frontansicht mit 8 antippbaren Setzstellen. Silhouette: Asset
/// „AIHubBodySilhouette" (Template-Rendering, transparenter Hintergrund),
/// bis es vorliegt eine einfache gezeichnete Figur. Zustände:
/// - Bearbeiten: alle Punkte sichtbar, genutzte gefüllt (Geräte-Farbe)
/// - Normal: nur genutzte Punkte; zuletzt genutzt = orange,
///   Vorschlag = grün mit Ring
private struct BodySiteView: View {
    let enabled: Set<AIHubDeviceHealth.Site>
    let lastUsed: AIHubDeviceHealth.Site?
    let suggestion: AIHubDeviceHealth.Site?
    let editMode: Bool
    let tint: Color
    let onTap: (AIHubDeviceHealth.Site) -> Void

    private static let assetName = "AIHubBodySilhouette"
    private static let assetAvailable = UIImage(named: assetName) != nil
    /// Seitenverhältnis des Silhouetten-Assets (700 × 1646).
    private static let figureAspect: CGFloat = 700.0 / 1646.0

    /// Relative Positionen (x, y) in 0…1 innerhalb der FIGUR-Box (nicht der
    /// View) — vermessen am Alpha-Kanal des Assets: Oberarm-Mitten bei
    /// x 0.22/0.78 (y 0.30), Torso 0.31–0.69, Hüfte 0.28–0.72,
    /// Bein-Mitten 0.39/0.61. Frontansicht: rechte Körperseite = links.
    private static let positions: [AIHubDeviceHealth.Site: CGPoint] = [
        .armRight: CGPoint(x: 0.22, y: 0.30),
        .armLeft: CGPoint(x: 0.78, y: 0.30),
        .abdomenRight: CGPoint(x: 0.42, y: 0.41),
        .abdomenLeft: CGPoint(x: 0.58, y: 0.41),
        .buttockRight: CGPoint(x: 0.33, y: 0.51),
        .buttockLeft: CGPoint(x: 0.67, y: 0.51),
        .thighRight: CGPoint(x: 0.39, y: 0.59),
        .thighLeft: CGPoint(x: 0.61, y: 0.59)
    ]

    /// scaledToFit-Rechteck der Figur, zentriert in der View.
    private func figureRect(in size: CGSize) -> CGRect {
        let height = min(size.height, size.width / Self.figureAspect)
        let width = height * Self.figureAspect
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let rect = figureRect(in: geometry.size)
            ZStack {
                silhouette(in: rect)
                ForEach(AIHubDeviceHealth.Site.allCases) { site in
                    if let position = Self.positions[site] {
                        siteDot(site)
                            .position(
                                x: rect.minX + position.x * rect.width,
                                y: rect.minY + position.y * rect.height
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder private func siteDot(_ site: AIHubDeviceHealth.Site) -> some View {
        let isEnabled = enabled.contains(site)
        let isLast = site == lastUsed
        let isSuggested = site == suggestion

        if editMode || isEnabled {
            Button {
                onTap(site)
            } label: {
                ZStack {
                    if isSuggested {
                        Circle()
                            .stroke(Color.green, lineWidth: 2)
                            .frame(width: 27, height: 27)
                    }
                    Circle()
                        .fill(dotColor(isEnabled: isEnabled, isLast: isLast, isSuggested: isSuggested))
                        .frame(width: 18, height: 18)
                    if editMode, isEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 38) // Tippfläche
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(site.label))
        }
    }

    private func dotColor(isEnabled: Bool, isLast: Bool, isSuggested: Bool) -> Color {
        if editMode { return isEnabled ? tint : Color(.systemGray4) }
        if isLast { return .orange }
        if isSuggested { return .green }
        return isEnabled ? Color(.systemGray3) : .clear
    }

    // MARK: - Silhouette

    @ViewBuilder private func silhouette(in rect: CGRect) -> some View {
        if Self.assetAvailable {
            Image(Self.assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint.opacity(0.30))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        } else {
            placeholderSilhouette(in: rect)
        }
    }

    /// Einfache Figur (Kopf, Rumpf, Arme, Beine) als Fallback ohne Asset.
    private func placeholderSilhouette(in rect: CGRect) -> some View {
        let width = rect.width
        let height = rect.height
        let fill = tint.opacity(0.18)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * width, y: rect.minY + y * height)
        }
        return ZStack {
            Circle()
                .fill(fill)
                .frame(width: 0.13 * height, height: 0.13 * height)
                .position(at(0.5, 0.08))
            RoundedRectangle(cornerRadius: 0.05 * height, style: .continuous)
                .fill(fill)
                .frame(width: 0.44 * width, height: 0.40 * height)
                .position(at(0.5, 0.36))
            Capsule()
                .fill(fill)
                .frame(width: 0.13 * width, height: 0.34 * height)
                .rotationEffect(.degrees(14))
                .position(at(0.20, 0.335))
            Capsule()
                .fill(fill)
                .frame(width: 0.13 * width, height: 0.34 * height)
                .rotationEffect(.degrees(-14))
                .position(at(0.80, 0.335))
            Capsule()
                .fill(fill)
                .frame(width: 0.17 * width, height: 0.42 * height)
                .position(at(0.39, 0.765))
            Capsule()
                .fill(fill)
                .frame(width: 0.17 * width, height: 0.42 * height)
                .position(at(0.61, 0.765))
        }
    }
}
