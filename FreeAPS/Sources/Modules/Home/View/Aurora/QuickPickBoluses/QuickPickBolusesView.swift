import SwiftUI

/// Quick-Pick Boluses picker sheet. Shows up to three learned bolus amounts as
/// pills; the user taps one and slides to enact (behind the normal biometric
/// unlock). Ported from Trio's Aurora Quick-Pick feature; localized via hubT.
struct QuickPickBolusesView: View {
    let suggestions: [Decimal]
    let onEnact: (Decimal) async -> Bool
    @Binding var isPresented: Bool

    @State private var selectedAmount: Decimal?
    @State private var showInfo = false
    @State private var isEnacting = false
    @State private var showAuthFailedAlert = false

    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    var body: some View {
        let titleText = hubT("qb.title")
        NavigationStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    pillRow
                        .padding(.top)

                    Text(hubT("qb.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .padding()

                    Spacer()
                }
            }.padding(.horizontal)
                .frame(maxWidth: .infinity)
                .safeAreaInset(edge: .bottom) {
                    VStack {
                        SlideToConfirmView(
                            label: hubT("qb.slide"),
                            isEnabled: selectedAmount != nil && !isEnacting
                        ) {
                            guard let amount = selectedAmount, !isEnacting else { return }
                            isEnacting = true
                            Task {
                                let success = await onEnact(amount)
                                await MainActor.run {
                                    if success {
                                        isPresented = false
                                    } else {
                                        isEnacting = false
                                        showAuthFailedAlert = true
                                    }
                                }
                            }
                        }.padding(.horizontal)
                    }
                    .padding(.horizontal)
                }
                .navigationTitle(titleText)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(titleText)
                            .font(.title3.bold())
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showInfo = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                }
                .sheet(isPresented: $showInfo) {
                    QuickPickBolusesInfoView(isPresented: $showInfo)
                }
                .alert(
                    hubT("qb.authfail.title"),
                    isPresented: $showAuthFailedAlert
                ) {
                    Button(hubT("qb.ok"), role: .cancel) {}
                } message: {
                    Text(hubT("qb.authfail.body"))
                }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isEnacting)
    }

    private var displayedSuggestions: [Decimal] {
        var seen = Set<Decimal>()
        return suggestions.prefix(3).filter { seen.insert($0).inserted }.sorted()
    }

    private var pillRow: some View {
        let pills = displayedSuggestions
        let isCompact = pills.count < 2
        return HStack(spacing: 16) {
            if isCompact { Spacer() }

            ForEach(pills, id: \.self) { amount in
                bolusAmountPill(amount)
                    .frame(maxWidth: isCompact ? 160 : .infinity)
            }

            if isCompact { Spacer() }
        }
        .padding(.horizontal)
    }

    private func bolusAmountPill(_ amount: Decimal) -> some View {
        let isSelected = selectedAmount == amount
        let formatted = Self.amountFormatter.string(from: amount as NSDecimalNumber) ?? amount.description

        return Button {
            selectedAmount = amount
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(formatted)
                    .font(.title2.bold())
                Text(hubT("qb.unit"))
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
