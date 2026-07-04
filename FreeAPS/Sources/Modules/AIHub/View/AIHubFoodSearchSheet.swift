import CoreData
import SwiftUI

/// Lebensmittel-Suche für den Mahlzeiten-Berater: hostet die komplette
/// AddCarbs-Suchmaschinerie (KI-Textsuche, Barcode-Scanner, Foto-Analyse,
/// OpenFoodFacts, Saved Foods) als eigenständiges Sheet.
///
/// Entscheidender Unterschied zu AddCarbs: „Übernehmen" speichert KEINEN
/// Carb-Eintrag — die ermittelten Nährwerte (inkl. Portionsanpassung)
/// fließen nur zurück in die Berater-Maske. Die Behandlung selbst geht
/// später wie gehabt über den offiziellen AddCarbs-/Bolus-Flow.
struct AIHubFoodSearchSheet: View {
    /// (Name, KH g, Fett g, Eiweiß g) der gewählten Portion(en).
    let onPick: (String, Double, Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var moc
    @StateObject private var searchState = FoodSearchStateModel()

    /// Gleiche Preset-Quelle wie AddCarbs — Saved Foods und der
    /// Favoriten-Stern in den Suchergebnissen arbeiten auf denselben Daten.
    @FetchRequest(
        entity: Presets.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)], predicate:
        NSCompoundPredicate(
            andPredicateWithSubpredicates: [
                NSPredicate(format: "dish != %@", " " as String),
                NSPredicate(format: "dish != %@", "Empty" as String)
            ]
        )
    ) private var carbPresets: FetchedResults<Presets>

    /// KI-Features wie in AddCarbs über das FreeAPS-Setting `ai` gegated.
    private let aiEnabled = BaseFileStorage()
        .retrieve(OpenAPS.FreeAPS.settings, as: FreeAPSSettings.self)?.ai ?? false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FoodSearchBar(ai: aiEnabled, state: searchState, showsSettings: false)
                    .padding(.horizontal)

                FoodSearchView(
                    state: searchState,
                    onContinue: { food, _, _ in
                        onPick(
                            food.name,
                            Double(truncating: (food.nutrientInThisPortion(.carbs) ?? 0) as NSNumber),
                            Double(truncating: (food.nutrientInThisPortion(.fat) ?? 0) as NSNumber),
                            Double(truncating: (food.nutrientInThisPortion(.protein) ?? 0) as NSNumber)
                        )
                        dismiss()
                    },
                    onHypoTreatment: nil,
                    onPersist: saveOrUpdatePreset,
                    onDelete: deletePreset,
                    // hubT liefert fertigen Text; der LocalizedStringKey-Lookup
                    // findet keinen Eintrag und zeigt ihn unverändert an.
                    continueButtonLabelKey: LocalizedStringKey(hubT("simfs.use")),
                    hypoTreatmentButtonLabelKey: "Hypo Treatment"
                )
            }
            .navigationTitle(hubT("simfs.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hubT("sim.savedfoods.cancel")) { dismiss() }
                }
            }
            .onAppear {
                // Immer im Such-Modus — es gibt hier keine Meal-Maske dahinter.
                searchState.showingFoodSearch = true
                updateSavedFoods()
            }
            .onChange(of: carbPresets.count) { _ in updateSavedFoods() }
            // „Speichern"-Aktion aus den Suchergebnissen: gleicher Editor wie
            // in AddCarbs — ohne dieses Sheet liefe der Stern ins Leere.
            .sheet(isPresented: $searchState.showNewSavedFoodEntry) {
                FoodItemEditorSheet(
                    existingItem: searchState.newFoodEntryToEdit,
                    title: NSLocalizedString("Add Food Manually", comment: ""),
                    allExistingTags: Set(searchState.savedFoods?.foodItems.flatMap { $0.tags ?? [] } ?? []),
                    showTagsAndFavorite: true,
                    onSave: { foodItem in
                        saveOrUpdatePreset(foodItem)
                        searchState.showNewSavedFoodEntry = false
                        searchState.newFoodEntryToEdit = nil
                    },
                    onCancel: {
                        searchState.showNewSavedFoodEntry = false
                        searchState.newFoodEntryToEdit = nil
                    }
                )
            }
        }
    }

    // MARK: - Saved-Foods-Anbindung (wie AddCarbsRootView)

    private func updateSavedFoods() {
        let foodItems = carbPresets.compactMap { FoodItemDetailed.fromPreset(preset: $0) }
        searchState.savedFoods = FoodItemGroup(
            foodItems: foodItems,
            briefDescription: nil,
            overallDescription: nil,
            diabetesConsiderations: nil,
            source: .database,
            barcode: nil,
            textQuery: nil
        )
    }

    private func saveOrUpdatePreset(_ food: FoodItemDetailed) {
        guard food.name.isNotEmpty else { return }
        let existing = carbPresets.first(where: { $0.foodID == food.id })
        let preset = existing ?? Presets(context: moc)
        food.updatePreset(preset: preset)
        do {
            try moc.save()
            updateSavedFoods()
        } catch {
            debug(.default, "AIHubFoodSearchSheet: couldn't save preset \(food.name)")
        }
    }

    private func deletePreset(_ food: FoodItemDetailed) {
        guard let preset = carbPresets.first(where: { $0.foodID == food.id }) else { return }
        moc.delete(preset)
        do {
            try moc.save()
            updateSavedFoods()
        } catch {
            debug(.default, "AIHubFoodSearchSheet: couldn't delete preset \(food.name)")
        }
    }
}
