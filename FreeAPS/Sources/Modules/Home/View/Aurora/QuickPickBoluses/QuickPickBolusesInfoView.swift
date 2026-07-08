import SwiftUI

/// Explainer sheet for the Quick-Pick Boluses feature.
/// Uses the Aurora/AI-Hub in-code localization (hubT), not Localizable.strings.
struct QuickPickBolusesInfoView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(hubT("qb.info.body"))
                    .padding()
            }
            .navigationTitle(hubT("qb.info.title"))
            .navigationBarTitleDisplayMode(.inline)

            Button {
                isPresented = false
            } label: {
                Text(hubT("qb.info.gotit"))
                    .bold()
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
            }
            .buttonStyle(.bordered)
            .padding([.horizontal, .bottom])
            .padding(.top, 4)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
