import SwiftUI
import StoreKit

struct ContentView: View {
    @StateObject private var purchaseManager = ProPurchaseManager()
    @State private var selectedTab: AppTab = .discover
    @State private var selectedCocktail: CocktailRowData?
    @State private var isLightMode = false
    @State private var houseCocktails: [CocktailRowData] = []
    @State private var selectedDiscoverCategory: DiscoverCategory = .all
    @State private var selectedCustomCategory: String?
    @State private var customCategories: [String] = []
    @State private var deletedOriginalNames: Set<String> = []
    @State private var pendingHouseDeletion: CocktailRowData?
    @State private var showingUpgrade = false
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            Group {
                switch selectedTab {
                case .discover:
                    DiscoverScreen(
                        selectedTab: $selectedTab,
                        selectedCocktail: $selectedCocktail,
                        selectedCategory: $selectedDiscoverCategory,
                        selectedCustomCategory: $selectedCustomCategory,
                        houseCocktails: $houseCocktails,
                        customCategories: $customCategories,
                        deletedOriginalNames: $deletedOriginalNames,
                        isLightMode: $isLightMode,
                        isPro: purchaseManager.isPro,
                        onPaidFeature: { showingUpgrade = true }
                    )
                case .bar:
                    MyBarScreen(selectedTab: $selectedTab, selectedCocktail: $selectedCocktail) {
                        showingSettings = true
                    }
                case .create:
                    CreateRecipeScreen(
                        selectedTab: $selectedTab,
                        selectedDiscoverCategory: $selectedDiscoverCategory,
                        houseCocktails: $houseCocktails,
                        isPro: purchaseManager.isPro,
                        onUpgrade: { showingUpgrade = true }
                    )
                }
            }

            if let selectedCocktail {
                DetailScreen(
                    cocktail: selectedCocktail,
                    isFavorite: houseCocktails.contains { $0.name == selectedCocktail.name },
                    onFavorite: {
                        toggleFavorite(selectedCocktail)
                    }
                ) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self.selectedCocktail = nil
                    }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: selectedCocktail?.id)
        .preferredColorScheme(isLightMode ? .light : .dark)
        .sheet(isPresented: $showingUpgrade) {
            UpgradePromptScreen {
                Task {
                    await purchaseManager.purchasePro()
                    if purchaseManager.isPro {
                        showingUpgrade = false
                    }
                }
            }
                .presentationDetents([.height(620), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsScreen(
                deletedCocktails: deletedOriginalNames.sorted(),
                onPaidFeature: { showingUpgrade = true },
                onRestore: { name in deletedOriginalNames.remove(name) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete cocktail?", isPresented: Binding(
            get: { pendingHouseDeletion != nil },
            set: { if !$0 { pendingHouseDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let pendingHouseDeletion {
                    removeFromHouse(pendingHouseDeletion)
                }
            }
        } message: {
            Text("This will delete \(pendingHouseDeletion?.name ?? "this cocktail") from the app.")
        }
    }

    private func toggleFavorite(_ cocktail: CocktailRowData) {
        if let existing = houseCocktails.first(where: { $0.name == cocktail.name }) {
            if existing.isUserCreated {
                pendingHouseDeletion = existing
            } else {
                removeFromHouse(existing)
            }
            return
        }

        var favorite = cocktail
        favorite.meta = DiscoverCategory.house.meta
        favorite.status = "HOUSE"
        favorite.statusColor = AppTheme.gold
        favorite.category = .house
        favorite.isUserCreated = false
        houseCocktails.append(favorite)
    }

    private func removeFromHouse(_ cocktail: CocktailRowData) {
        houseCocktails.removeAll { $0.name == cocktail.name }
        if selectedCocktail?.name == cocktail.name {
            selectedCocktail = nil
        }
    }
}

private enum AppTab: String, CaseIterable {
    case discover = "Menu"
    case bar = "Bar"
    case create = "Create"

    var icon: String {
        switch self {
        case .discover:
            "circle.circle"
        case .bar:
            "circle.lefthalf.filled"
        case .create:
            "plus"
        }
    }
}

private enum AppTheme {
    static let background = Color("AppBackground")
    static let surface = Color("AppSurface")
    static let activeSurface = Color("AppActiveSurface")
    static let text = Color("AppText")
    static let darkText = Color(red: 0.090, green: 0.086, blue: 0.078)
    static let gold = Color(red: 0.780, green: 0.651, blue: 0.412)
    static let muted = Color("AppMuted")
    static let quiet = Color("AppQuiet")
    static let ready = Color("AppReady")
    static let border = Color("AppBorder")
}

@MainActor
private final class ProPurchaseManager: ObservableObject {
    private let productId = "pro"
    @Published var isPro = false

    func purchasePro() async {
        do {
            guard let product = try await Product.products(for: [productId]).first else {
                return
            }
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    isPro = true
                    await transaction.finish()
                }
            default:
                break
            }
        } catch {
            // StoreKit surfaces cancellation and configuration issues; keep the paywall available.
        }
    }
}

private struct DiscoverScreen: View {
    @Binding var selectedTab: AppTab
    @Binding var selectedCocktail: CocktailRowData?
    @Binding var selectedCategory: DiscoverCategory
    @Binding var selectedCustomCategory: String?
    @Binding var houseCocktails: [CocktailRowData]
    @Binding var customCategories: [String]
    @Binding var deletedOriginalNames: Set<String>
    @Binding var isLightMode: Bool
    let isPro: Bool
    let onPaidFeature: () -> Void
    @State private var searchText = ""
    @State private var showingNewCategoryPrompt = false
    @State private var newCategoryName = ""
    @State private var actionCocktail: CocktailRowData?
    @State private var hasShownOriginalDeleteWarning = false

    private var cocktails: [CocktailRowData] {
        let builtIns = CocktailCatalog.cocktails(for: .all).filter { !deletedOriginalNames.contains($0.name) }
        let categoryCocktails: [CocktailRowData]
        if let selectedCustomCategory {
            categoryCocktails = houseCocktails.filter { $0.customCategory == selectedCustomCategory }
        } else {
            categoryCocktails = switch selectedCategory {
            case .all:
                builtIns + houseCocktails
            case .house:
                houseCocktails
            default:
                CocktailCatalog.cocktails(for: selectedCategory).filter { !deletedOriginalNames.contains($0.name) }
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return categoryCocktails
        }

        return categoryCocktails.filter { cocktail in
            cocktail.matchesSearch(query)
        }
    }

    var body: some View {
        AppScreen(selectedTab: $selectedTab, tab: .discover) {
            HStack(alignment: .top) {
                HeaderBlock(eyebrow: "COCKTAILS", title: "Menu")
                ThemeToggle(isLightMode: $isLightMode)
                    .padding(.top, 18)
            }
            SearchField(text: $searchText, placeholder: "Search by name or ingredient")
            CategoryChips(
                selectedCategory: $selectedCategory,
                selectedCustomCategory: $selectedCustomCategory,
                customCategories: $customCategories,
                isPro: isPro,
                onAddCategory: {
                    if isPro {
                        showingNewCategoryPrompt = true
                    } else {
                        onPaidFeature()
                    }
                },
                onPaidFeature: onPaidFeature
            )
            SectionLabel(selectedCustomCategory?.uppercased() ?? selectedCategory.sectionTitle)

            VStack(spacing: 10) {
                if selectedCategory == .house, cocktails.isEmpty {
                    HouseEmptyState()
                } else {
                    ForEach(cocktails) { cocktail in
                        Button {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                selectedCocktail = cocktail
                            }
                        } label: {
                            CocktailListRow(cocktail: cocktail)
                        }
                        .buttonStyle(.plain)
                        .onLongPressGesture {
                            actionCocktail = cocktail
                        }
                    }
                }
            }
        }
        .alert("New category", isPresented: $showingNewCategoryPrompt) {
            TextField("Category name", text: $newCategoryName)
            Button("Cancel", role: .cancel) { newCategoryName = "" }
            Button("Add") {
                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !customCategories.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    customCategories.append(name)
                    selectedCustomCategory = name
                }
                newCategoryName = ""
            }
        }
        .confirmationDialog("Cocktail", isPresented: Binding(
            get: { actionCocktail != nil },
            set: { if !$0 { actionCocktail = nil } }
        )) {
            Button("Change Category") {
                if isPro {
                    // Category assignment UI will be added once Pro data persistence is connected.
                } else {
                    onPaidFeature()
                }
                actionCocktail = nil
            }
            Button("Delete", role: .destructive) {
                guard let actionCocktail else { return }
                guard isPro else {
                    onPaidFeature()
                    self.actionCocktail = nil
                    return
                }
                if actionCocktail.isUserCreated {
                    houseCocktails.removeAll { $0.name == actionCocktail.name }
                } else {
                    if !hasShownOriginalDeleteWarning {
                        hasShownOriginalDeleteWarning = true
                    }
                    deletedOriginalNames.insert(actionCocktail.name)
                }
                self.actionCocktail = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Change Category and deleting original cocktails are Pro features. Deleted original cocktails can be restored from Settings.")
        }
    }
}

private struct MyBarScreen: View {
    @Binding var selectedTab: AppTab
    @Binding var selectedCocktail: CocktailRowData?
    let onSettings: () -> Void
    @State private var searchText = ""
    @State private var onHandIngredients: [BarIngredient] = []

    private var availableIngredients: [BarIngredient] {
        BarIngredient.availableIngredients
    }

    private var matchingIngredients: [BarIngredient] {
        let query = searchText.normalizedForSearch
        guard !query.isEmpty else {
            return []
        }

        let selected = Set(onHandIngredients.map(\.key))
        return availableIngredients
            .filter { !selected.contains($0.key) }
            .filter { $0.name.normalizedForSearch.contains(query) || $0.key.contains(query) }
            .prefix(8)
            .map { $0 }
    }

    private var onHandKeys: Set<String> {
        Set(onHandIngredients.map(\.key))
    }

    private var makeableCocktails: [CocktailRowData] {
        CocktailCatalog.cocktails(for: .all)
            .filter { $0.missingIngredients(from: onHandKeys).isEmpty }
            .map {
                var cocktail = $0
                cocktail.status = "ready"
                cocktail.statusColor = AppTheme.ready
                cocktail.meta = "all ingredients ready"
                return cocktail
            }
    }

    private var bestUnlock: (ingredient: BarIngredient, count: Int)? {
        let lockedByIngredient = CocktailCatalog.cocktails(for: .all)
            .reduce(into: [BarIngredient: Int]()) { result, cocktail in
                let missing = cocktail.missingIngredients(from: onHandKeys)
                guard missing.count == 1, let ingredient = missing.first else {
                    return
                }
                result[ingredient, default: 0] += 1
            }

        return lockedByIngredient
            .filter { !onHandKeys.contains($0.key.key) }
            .max { lhs, rhs in lhs.value < rhs.value }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        AppScreen(selectedTab: $selectedTab, tab: .bar) {
            HStack(alignment: .top) {
                HeaderBlock(eyebrow: "YOUR INGREDIENTS", title: "My Bar")
                SettingsButton(action: onSettings)
                    .padding(.top, 18)
            }
            SearchField(text: $searchText, placeholder: "Find or add ingredient")

            if !matchingIngredients.isEmpty {
                VStack(spacing: 8) {
                    ForEach(matchingIngredients) { ingredient in
                        Button {
                            addIngredient(ingredient)
                        } label: {
                            IngredientSuggestionRow(ingredient: ingredient)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("READY TONIGHT")
                DisplayTitle("\(makeableCocktails.count) \(makeableCocktails.count == 1 ? "cocktail" : "cocktails")", size: 30, lineHeight: 34)
                Text(unlockCopy)
                    .appBody(size: 13, color: AppTheme.muted, lineHeight: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(AppTheme.activeSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("ON HAND")
                if onHandIngredients.isEmpty {
                    Text("Pick ingredients from search to start building your bar.")
                        .appBody(size: 13, color: AppTheme.muted, lineHeight: 18)
                } else {
                    FlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(onHandIngredients) { ingredient in
                            Button {
                                removeIngredient(ingredient)
                            } label: {
                                IngredientChip(name: ingredient.name, color: ingredient.color)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(ingredient.name)")
                        }
                    }
                    .frame(minHeight: 34, alignment: .topLeading)
                }
            }

            SectionLabel("SUGGESTED")
            VStack(spacing: 10) {
                if makeableCocktails.isEmpty {
                    Text("Add ingredients to see what you can make.")
                        .appBody(size: 13, color: AppTheme.muted, lineHeight: 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(makeableCocktails) { cocktail in
                        Button {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                selectedCocktail = cocktail
                            }
                        } label: {
                            CocktailListRow(cocktail: cocktail)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var unlockCopy: String {
        guard let bestUnlock else {
            return onHandIngredients.isEmpty ? "Add an ingredient to unlock recipe suggestions." : "No single ingredient unlocks more recipes right now."
        }

        return "Add \(bestUnlock.ingredient.name.lowercased()) to unlock \(bestUnlock.count) more \(bestUnlock.count == 1 ? "recipe" : "recipes")."
    }

    private func addIngredient(_ ingredient: BarIngredient) {
        guard !onHandKeys.contains(ingredient.key) else {
            return
        }

        onHandIngredients.append(ingredient)
        onHandIngredients.sort { $0.name < $1.name }
        searchText = ""
    }

    private func removeIngredient(_ ingredient: BarIngredient) {
        onHandIngredients.removeAll { $0.key == ingredient.key }
    }
}

private struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.gold)
                .frame(width: 44, height: 32)
                .background(AppTheme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

private struct UpgradePromptScreen: View {
    @Environment(\.dismiss) private var dismiss
    let onPurchase: () -> Void
    private let features = [
        ("Unlimited custom cocktails", "Free users can create 2. Pro unlocks every house recipe."),
        ("Ingredient substitutions", "Find useful swaps when your home bar is missing something."),
        ("Add own ingredients", "Extend the pantry with your own bottles, syrups and garnishes."),
        ("Shopping list", "Save missing ingredients from recipes and suggestions."),
        ("Custom collections", "Build Date Night, Summer, Whiskey, Party Menu and more."),
        ("Recipe notes and ratings", "Add tasting notes and ratings to your own cocktails."),
        ("Custom app icons", "Choose the icon that fits your home screen.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    SectionLabel("ON THE ROCKS PRO")
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                            .frame(width: 38, height: 38)
                            .background(AppTheme.surface)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                DisplayTitle("Become a\nMixologist", size: 44, lineHeight: 48)
                Text("Unlock the tools to build a personal cocktail bar.")
                    .appBody(size: 16, color: AppTheme.muted, lineHeight: 24)

                VStack(spacing: 10) {
                    ForEach(features, id: \.0) { feature in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(AppTheme.gold)
                                .frame(width: 9, height: 9)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.0)
                                    .appBody(size: 15, weight: .semibold, color: AppTheme.text, lineHeight: 20)
                                Text(feature.1)
                                    .appBody(size: 13, color: AppTheme.muted, lineHeight: 18)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Button(action: onPurchase) {
                    Text("Upgrade to Pro - £2.99")
                        .appBody(size: 16, weight: .semibold, color: AppTheme.darkText, lineHeight: 20)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppTheme.gold)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
        .background(AppTheme.background)
    }
}

private struct SettingsScreen: View {
    let deletedCocktails: [String]
    let onPaidFeature: () -> Void
    let onRestore: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderBlock(eyebrow: "SETTINGS", title: "Settings")
                settingsRow("Shopping Cart", paid: true, action: onPaidFeature)
                settingsRow("My Pantry", paid: true, action: onPaidFeature)
                settingsRow("Change App Icon", paid: true, action: onPaidFeature)

                SectionLabel("RESTORE COCKTAILS")
                    .padding(.top, 10)
                if deletedCocktails.isEmpty {
                    Text("Deleted original cocktails will appear here.")
                        .appBody(size: 14, color: AppTheme.muted, lineHeight: 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(deletedCocktails, id: \.self) { name in
                        HStack {
                            Text(name)
                                .appBody(size: 15, color: AppTheme.text, lineHeight: 20)
                            Spacer()
                            Button("Restore") { onRestore(name) }
                                .buttonStyle(.bordered)
                                .tint(AppTheme.gold)
                        }
                        .padding(16)
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(24)
        }
        .background(AppTheme.background)
    }

    private func settingsRow(_ title: String, paid: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .appBody(size: 16, weight: .semibold, color: AppTheme.text, lineHeight: 22)
                Spacer()
                if paid {
                    Text("PRO")
                        .appBody(size: 11, weight: .semibold, color: AppTheme.gold, lineHeight: 14)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(16)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct CreateRecipeScreen: View {
    @Binding var selectedTab: AppTab
    @Binding var selectedDiscoverCategory: DiscoverCategory
    @Binding var houseCocktails: [CocktailRowData]
    let isPro: Bool
    let onUpgrade: () -> Void
    @State private var recipeName = ""
    @State private var selectedGlass: GlassStyle?
    @State private var selectedIngredients: [DraftIngredient] = []
    @State private var ingredientSearch = ""
    @State private var isAddingIngredient = false
    @State private var draftStep = ""
    @State private var isAddingStep = false
    @FocusState private var stepInputFocused: Bool

    private var matchingIngredients: [BarIngredient] {
        let selectedKeys = Set(selectedIngredients.map(\.ingredient.key))
        let available = BarIngredient.availableIngredients.filter { !selectedKeys.contains($0.key) }
        let query = ingredientSearch.normalizedForSearch

        guard !query.isEmpty else {
            return Array(available.prefix(8))
        }

        return available
            .filter { $0.name.normalizedForSearch.contains(query) || $0.key.contains(query) }
            .prefix(8)
            .map { $0 }
    }

    private var canSave: Bool {
        !recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedGlass != nil &&
        !selectedIngredients.isEmpty &&
        !methodSteps.isEmpty
    }

    private var methodSteps: [String] {
        draftMethodSteps
    }

    @State private var draftMethodSteps: [String] = []

    var body: some View {
        AppScreen(selectedTab: $selectedTab, tab: .create, gap: 14) {
            HeaderBlock(eyebrow: "CUSTOM RECIPE", title: "Create")
            FormTextField(label: "NAME", placeholder: "Recipe name", text: $recipeName)
            GlassPickerField(selectedGlass: $selectedGlass)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("INGREDIENTS")
                if selectedIngredients.isEmpty {
                    EmptyRecipeCopy("No ingredients added yet.")
                } else {
                    ForEach($selectedIngredients) { $ingredient in
                        EditableIngredient(ingredient: $ingredient) {
                            selectedIngredients.removeAll { $0.id == ingredient.id }
                        }
                    }
                }
            }

            VStack(spacing: 10) {
                RecipeActionButton(title: "Add ingredient") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAddingIngredient.toggle()
                    }
                }

                if isAddingIngredient {
                    SearchField(text: $ingredientSearch, placeholder: "Search ingredients")
                    VStack(spacing: 8) {
                        ForEach(matchingIngredients) { ingredient in
                            Button {
                                addIngredient(ingredient)
                            } label: {
                                IngredientSuggestionRow(ingredient: ingredient)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("METHOD")
                if methodSteps.isEmpty {
                    EmptyRecipeCopy("No steps added yet.")
                } else {
                    ForEach(Array(methodSteps.enumerated()), id: \.offset) { index, step in
                        DraftStepRow(number: index + 1, text: step) {
                            draftMethodSteps.removeAll { $0 == step }
                        }
                    }
                }
            }

            VStack(spacing: 10) {
                RecipeActionButton(title: "Add Step") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAddingStep = true
                    }
                    DispatchQueue.main.async {
                        stepInputFocused = true
                    }
                }

                if isAddingStep {
                    VStack(spacing: 10) {
                        FormTextField(
                            label: "STEP",
                            placeholder: "Describe the next step",
                            text: $draftStep,
                            height: 86,
                            axis: .vertical,
                            capitalization: .sentences,
                            focused: $stepInputFocused
                        )
                        Button {
                            addStep()
                        } label: {
                            Text("Save step")
                                .appBody(size: 14, weight: .semibold, color: AppTheme.darkText, lineHeight: 18)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(AppTheme.gold.opacity(draftStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(draftStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            Button {
                saveRecipe()
            } label: {
                Text("Save recipe")
                    .appBody(size: 15, weight: .semibold, color: AppTheme.darkText, lineHeight: 20)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AppTheme.gold.opacity(canSave ? 1 : 0.35))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
    }

    private func addIngredient(_ ingredient: BarIngredient) {
        selectedIngredients.append(DraftIngredient(ingredient: ingredient))
        ingredientSearch = ""
        isAddingIngredient = false
    }

    private func addStep() {
        let step = draftStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !step.isEmpty else { return }
        draftMethodSteps.append(step)
        draftStep = ""
        isAddingStep = false
    }

    private func saveRecipe() {
        let trimmedName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, let glass = selectedGlass else { return }
        if !isPro, houseCocktails.filter(\.isUserCreated).count >= 2 {
            onUpgrade()
            return
        }

        let layers = selectedIngredients.map { DrinkLayer.forIngredientKey($0.ingredient.key) }
        let ingredients = selectedIngredients.map(\.ingredientLine)
        let method = methodSteps.joined(separator: ". ")
        let proportions = zip(selectedIngredients, layers).map { ingredient, layer in
            CocktailProportion(name: ingredient.ingredientLine, amount: ingredient.proportionAmount, layer: layer)
        }

        houseCocktails.append(
            CocktailRowData(
                name: trimmedName,
                meta: DiscoverCategory.house.meta,
                status: "HOUSE",
                statusColor: AppTheme.gold,
                layers: layers.isEmpty ? [.amber] : layers,
                category: .house,
                glassStyle: glass,
                ingredients: ingredients,
                method: method,
                garnish: "No garnish listed.",
                flavorProfile: "A house recipe built from your selected ingredients.",
                proportions: proportions,
                isUserCreated: true
            )
        )

        resetForm()
        selectedDiscoverCategory = .house
        selectedTab = .discover
    }

    private func resetForm() {
        recipeName = ""
        selectedGlass = nil
        selectedIngredients = []
        ingredientSearch = ""
        isAddingIngredient = false
        draftStep = ""
        draftMethodSteps = []
        isAddingStep = false
    }
}

private struct DetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var swishProgress: CGFloat = 1
    let cocktail: CocktailRowData
    let isFavorite: Bool
    let onFavorite: () -> Void
    var onClose: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom
            let compactScale = min(0.65, max(0.48, availableHeight / 960))

            AppTheme.background
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        CircleIconButton(systemName: "chevron.left") {
                            close()
                        }
                        Spacer()
                        CircleIconButton(systemName: isFavorite ? "heart.fill" : "heart") {
                            onFavorite()
                        }
                    }

                    CocktailGlass(
                        layers: cocktail.layers,
                        proportions: cocktail.proportions,
                        style: cocktail.glassStyle,
                        scale: compactScale,
                        swishProgress: swishProgress
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: 268 * compactScale / 0.65)

                    VStack(alignment: .leading, spacing: 9) {
                        SectionLabel(cocktail.detailEyebrow)
                        DisplayTitle(cocktail.name, size: 40, lineHeight: 44)
                        Text(cocktail.flavorProfile)
                            .appBody(size: 15, color: AppTheme.muted, lineHeight: 22)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("PROPORTIONS")
                        ProportionsBar(items: cocktail.proportions)
                            .frame(height: 28)
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("INGREDIENTS")
                        ForEach(cocktail.ingredientRows) { ingredient in
                            IngredientAmount(name: ingredient.name, amount: ingredient.amount)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("METHOD")
                        ForEach(cocktail.methodSteps) { step in
                            RecipeStepRow(step: step)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("GARNISH")
                        Text(cocktail.garnish)
                            .appBody(size: 15, color: AppTheme.muted, lineHeight: 22)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, max(20, proxy.safeAreaInsets.top + 8))
                .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 24))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    guard value.startLocation.x < 36 else { return }
                    if value.translation.width > 70, abs(value.translation.height) < 80 {
                        close()
                    }
                }
        )
        .onAppear {
            swishProgress = 0
            withAnimation(.easeOut(duration: 2.65)) {
                swishProgress = 1
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct AppScreen<Content: View>: View {
    @Binding var selectedTab: AppTab
    let tab: AppTab
    var gap: CGFloat = 20
    @ViewBuilder let content: Content

    init(selectedTab: Binding<AppTab>, tab: AppTab, gap: CGFloat = 20, @ViewBuilder content: () -> Content) {
        _selectedTab = selectedTab
        self.tab = tab
        self.gap = gap
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: gap) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, max(18, proxy.safeAreaInsets.top + 6))
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(96, proxy.safeAreaInsets.bottom + 76))
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                BottomNav(selectedTab: $selectedTab)
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(8, proxy.safeAreaInsets.bottom - 14))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

private struct HeaderBlock: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: title == "Menu" ? 12 : 10) {
            SectionLabel(eyebrow)
            DisplayTitle(title, size: 38, lineHeight: 42)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HouseEmptyState: View {
    var body: some View {
        (
            Text("This is a home for all of your favourites, and any of your own creations. Start by favouriting any of the existing cocktails from our menu, or by heading to ")
                .font(.system(size: 14, weight: .regular))
            + Text("Create")
                .font(.system(size: 14, weight: .bold))
            + Text(" in the menu below.")
                .font(.system(size: 14, weight: .regular))
        )
        .foregroundStyle(AppTheme.muted)
        .lineSpacing(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ThemeToggle: View {
    @Binding var isLightMode: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                isLightMode.toggle()
            }
        } label: {
            Image(systemName: isLightMode ? "moon" : "sun.max")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isLightMode ? AppTheme.text : AppTheme.gold)
                .frame(width: 44, height: 32)
                .background(AppTheme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLightMode ? "Switch to dark mode" : "Switch to light mode")
    }
}

private struct DisplayTitle: View {
    let text: String
    let size: CGFloat
    let lineHeight: CGFloat

    init(_ text: String, size: CGFloat, lineHeight: CGFloat) {
        self.text = text
        self.size = size
        self.lineHeight = lineHeight
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .regular, design: .serif))
            .foregroundStyle(AppTheme.text)
            .lineSpacing(max(0, lineHeight - size))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.32)
            .foregroundStyle(AppTheme.gold)
            .lineLimit(1)
    }
}

private struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.quiet)
            TextField(placeholder, text: $text)
                .focused($isFocused)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.text)
                .tint(AppTheme.gold)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    isFocused = false
                }
                .lineLimit(1)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.quiet)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .background(AppTheme.surface)
        .clipShape(Capsule())
    }
}

private struct FilterChips: View {
    let chips: [String]
    let active: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .appBody(size: 12, weight: .medium, color: chip == active ? AppTheme.text : AppTheme.muted, lineHeight: 16)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(chip == active ? AppTheme.activeSurface : AppTheme.surface)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct CategoryChips: View {
    @Binding var selectedCategory: DiscoverCategory
    @Binding var selectedCustomCategory: String?
    @Binding var customCategories: [String]
    let isPro: Bool
    let onAddCategory: () -> Void
    let onPaidFeature: () -> Void
    @State private var editingCategory: String?
    @State private var renameText = ""

    var body: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(DiscoverCategory.allCases, id: \.self) { category in
                categoryButton(
                    title: category.title,
                    selected: selectedCustomCategory == nil && category == selectedCategory
                ) {
                    selectedCustomCategory = nil
                    selectedCategory = category
                }
                .onLongPressGesture {
                    if category != .all { onPaidFeature() }
                }
            }

            ForEach(customCategories, id: \.self) { category in
                categoryButton(title: category, selected: selectedCustomCategory == category) {
                    selectedCustomCategory = category
                }
                .onLongPressGesture {
                    if isPro {
                        editingCategory = category
                        renameText = category
                    } else {
                        onPaidFeature()
                    }
                }
            }

            Button(action: onAddCategory) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .confirmationDialog("Category", isPresented: Binding(
            get: { editingCategory != nil },
            set: { if !$0 { editingCategory = nil } }
        )) {
            Button("Rename") { onPaidFeature() }
            Button("Delete", role: .destructive) {
                guard isPro else {
                    onPaidFeature()
                    return
                }
                if let editingCategory {
                    customCategories.removeAll { $0 == editingCategory }
                    if selectedCustomCategory == editingCategory {
                        selectedCustomCategory = nil
                        selectedCategory = .all
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func categoryButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .appBody(size: 12, weight: .medium, color: selected ? AppTheme.text : AppTheme.muted, lineHeight: 16)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(selected ? AppTheme.activeSurface : AppTheme.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private enum DiscoverCategory: String, CaseIterable {
    case all
    case oldSchool
    case classics
    case house

    var title: String {
        switch self {
        case .all:
            "All"
        case .oldSchool:
            "Old School"
        case .classics:
            "Classics"
        case .house:
            "House"
        }
    }

    var sectionTitle: String {
        switch self {
        case .all:
            "ALL COCKTAILS"
        case .oldSchool:
            "OLD SCHOOL"
        case .classics:
            "CLASSICS"
        case .house:
            "HOUSE"
        }
    }

    var meta: String {
        switch self {
        case .all:
            "iba"
        case .oldSchool:
            "old school · iba"
        case .classics:
            "classic · iba"
        case .house:
            "house"
        }
    }

    var layers: [DrinkLayer] {
        switch self {
        case .all:
            [.vermouth, .campari, .gin]
        case .oldSchool:
            [.bourbon, .orange]
        case .classics:
            [.lime, .white]
        case .house:
            [.amber, .orange]
        }
    }

}

private enum CocktailCatalog {
    static func cocktails(for category: DiscoverCategory) -> [CocktailRowData] {
        switch category {
        case .all:
            return all
        case .oldSchool:
            return oldSchool
        case .classics:
            return classics
        case .house:
            return []
        }
    }

    private static let oldSchoolNames = [
        "Alexander", "Americano", "Angel Face", "Aviation", "Between the Sheets", "Boulevardier",
        "Brandy Crusta", "Casino", "Clover Club", "Daiquiri", "Dry Martini", "Gin Fizz",
        "Hanky Panky", "John Collins", "Last Word", "Manhattan", "Martinez", "Mary Pickford",
        "Monkey Gland", "Negroni", "Old Fashioned", "Paradise", "Planters Punch", "Porto Flip",
        "Ramos Fizz", "Remember the Maine", "Rusty Nail", "Sazerac", "Sidecar", "Stinger",
        "Tuxedo", "Vieux Carré", "Whiskey Sour", "White Lady"
    ]

    private static let classicNames = [
        "Bellini", "Black Russian", "Bloody Mary", "Caipirinha", "Cardinale", "Champagne Cocktail",
        "Corpse Reviver #2", "Cosmopolitan", "Cuba Libre", "French 75", "French Connection",
        "Garibaldi", "Grasshopper", "Hemingway Special", "Horse’s Neck", "Irish Coffee", "Kir",
        "Lemon Drop Martini", "Long Island Iced Tea", "Mai-Tai", "Margarita", "Mimosa",
        "Mint Julep", "Mojito", "Moscow Mule", "Pina Colada", "Pisco Sour", "Rabo de Galo",
        "Sea Breeze", "Sex on the Beach", "Singapore Sling", "Tequila Sunrise", "Vesper", "Zombie",
        "Bee’s Knees", "Bramble", "Canchanchara", "Chartreuse Swizzle", "Dark ‘N’ Stormy",
        "Don's Special Daiquiri", "Espresso Martini", "Fernandito", "French Martini",
        "Gin Basil Smash", "Grand Margarita", "IBA Tiki", "Illegal", "Jungle Bird",
        "Missionary's Downfall", "Naked and Famous", "New York Sour", "Old Cuban", "Paloma",
        "Paper Plane", "Penicillin", "Pisco Punch", "Porn Star Martini", "Russian Spring Punch",
        "Sherry Cobbler", "South Side", "Spicy Fifty", "Spritz", "Suffering Bastard",
        "Three Dots and a Dash", "Tipperary", "Tommy's Margarita", "Trinidad Sour", "Ve.N.To"
    ]

    private static let oldSchool = rows(from: oldSchoolNames, category: .oldSchool)
    private static let classics = rows(from: classicNames, category: .classics)
    private static let all = oldSchool + classics

    private static func rows(from names: [String], category: DiscoverCategory) -> [CocktailRowData] {
        names.map { name in
            let details = details(for: name, category: category)
            let methodNote = note(in: details.method)
            return CocktailRowData(
                name: name,
                meta: category.meta,
                status: "IBA",
                statusColor: AppTheme.gold,
                layers: layers(for: name, category: category),
                category: category,
                glassStyle: glassStyle(for: name),
                ingredients: details.ingredients,
                method: methodWithoutNote(details.method),
                garnish: details.garnish,
                flavorProfile: flavorProfile(for: name, category: category, note: methodNote),
                proportions: proportions(for: name, category: category, details: details)
            )
        }
    }

    private static func details(for name: String, category: DiscoverCategory) -> CocktailDetails {
        if let details = drinkDetails[name] {
            return details
        }

        return CocktailDetails(
            ingredients: layers(for: name, category: category).map(\.title),
            method: "Prepare and serve according to the IBA specification.",
            garnish: "No garnish listed."
        )
    }

    private static func flavorProfile(for name: String, category: DiscoverCategory, note: String?) -> String {
        let profile: String
        if let savedProfile = flavorProfiles[name] {
            profile = savedProfile
        } else {
            let layers = layers(for: name, category: category).map(\.flavorNote)
            let notes = Array(NSOrderedSet(array: layers).compactMap { $0 as? String }).prefix(3)
            profile = "A \(notes.joined(separator: ", ")) cocktail with a balanced finish."
        }

        guard let note, !note.isEmpty else {
            return profile
        }
        return "\(profile) Note: \(note)"
    }

    private static func methodWithoutNote(_ method: String) -> String {
        method.replacingOccurrences(of: #"(?i)\s+NOTE:\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+Note:\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func note(in method: String) -> String? {
        guard let match = method.firstMatch(pattern: #"(?i)\bNOTE:\s+(.+)$"#) ??
            method.firstMatch(pattern: #"(?i)\bNote:\s+(.+)$"#) else {
            return nil
        }
        return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func proportions(for name: String, category: DiscoverCategory, details: CocktailDetails) -> [CocktailProportion] {
        let measured = details.ingredients.compactMap { ingredient -> CocktailProportion? in
            guard let amount = measuredMilliliters(in: ingredient) else { return nil }
            return CocktailProportion(name: ingredient, amount: amount, layer: layer(forIngredient: ingredient, cocktailName: name))
        }

        if !measured.isEmpty {
            return measured
        }

        return layers(for: name, category: category).map {
            CocktailProportion(name: $0.title, amount: 1, layer: $0)
        }
    }

    private static func measuredMilliliters(in ingredient: String) -> Double? {
        let lower = ingredient.lowercased()
        if lower.contains("dash") || lower.contains("drop") || lower.contains("bar spoon") ||
            lower.contains("teaspoon") || lower.contains("tsp") || lower.contains("pcs") ||
            lower.contains("slice") || lower.contains("sprig") || lower.contains("pinch") ||
            lower.contains("splash") || lower.contains("top") || lower.contains("fill up") ||
            lower.contains("soda water") {
            return nil
        }

        let pattern = #"(\d+(?:\.\d+)?)\s*ml"#
        if let range = ingredient.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let match = String(ingredient[range]).lowercased().replacingOccurrences(of: "ml", with: "").trimmingCharacters(in: .whitespaces)
            return Double(match)
        }

        let leadingPattern = #"^\s*(\d+(?:\.\d+)?)\s+"#
        if let range = ingredient.range(of: leadingPattern, options: .regularExpression) {
            return Double(ingredient[range].trimmingCharacters(in: .whitespaces))
        }

        return nil
    }

    private static func layer(forIngredient ingredient: String, cocktailName: String) -> DrinkLayer {
        let text = ingredient.lowercased()

        if text.contains("grand marnier") || text.contains("orange curacao") || text.contains("curacao") ||
            text.contains("cointreau") || text.contains("triple sec") {
            return .orange
        }
        if text.contains("tequila") || text.contains("mezcal") {
            return .amber
        }
        if text.contains("gin") {
            return .gin
        }
        if text.contains("vodka") || text.contains("white rum") || text.contains("cuban ron") || text.contains("aguardiente") {
            return .clear
        }
        if text.contains("rum") || text.contains("rhum") {
            return text.contains("dark") || text.contains("blackstrap") || text.contains("aged") ? .darkRum : .amber
        }
        if text.contains("whiskey") || text.contains("whisky") || text.contains("bourbon") || text.contains("rye") || text.contains("scotch") {
            return .whiskey
        }
        if text.contains("cognac") || text.contains("brandy") || text.contains("calvados") {
            return .brandy
        }
        if text.contains("vermouth") {
            return text.contains("dry") ? .clear : .vermouth
        }
        if text.contains("campari") || text.contains("aperol") {
            return .campari
        }
        if text.contains("lime") {
            return .lime
        }
        if text.contains("lemon") {
            return .lemon
        }
        if text.contains("orange") {
            return .orange
        }
        if text.contains("grapefruit") {
            return .grapefruit
        }
        if text.contains("pineapple") {
            return .pineapple
        }
        if text.contains("cranberry") {
            return .cranberry
        }
        if text.contains("passion") {
            return .passion
        }
        if text.contains("peach") {
            return .peach
        }
        if text.contains("raspberry") {
            return .raspberry
        }
        if text.contains("cassis") || text.contains("mûre") || text.contains("mure") {
            return .berry
        }
        if text.contains("cherry") || text.contains("maraschino") {
            return .cherry
        }
        if text.contains("coffee") || text.contains("kahl") || text.contains("espresso") {
            return .coffee
        }
        if text.contains("cream") || text.contains("coconut") {
            return .cream
        }
        if text.contains("honey") {
            return .honey
        }
        if text.contains("agave") {
            return .agave
        }
        if text.contains("mint") || text.contains("menthe") {
            return .mint
        }
        if text.contains("chartreuse") {
            return .chartreuse
        }
        if text.contains("cola") {
            return .cola
        }
        if text.contains("ginger") {
            return .ginger
        }
        if text.contains("tomato") {
            return .tomato
        }
        if text.contains("grenadine") {
            return .grenadine
        }
        if text.contains("prosecco") || text.contains("champagne") || text.contains("sparkling") {
            return .sparkling
        }
        if text.contains("wine") || text.contains("port") {
            return text.contains("red") || text.contains("tawny") ? .rubyPort : .white
        }
        if text.contains("amaro") || text.contains("cynar") || text.contains("fernet") {
            return .amaro
        }
        if text.contains("almond") || text.contains("orgeat") || text.contains("amaretto") {
            return .almond
        }

        return layers(for: cocktailName, category: .all).first ?? .amber
    }

    private static func glassStyle(for name: String) -> GlassStyle {
        if rocksGlass.contains(name) {
            return .rocks
        }
        if highballGlass.contains(name) {
            return .highball
        }
        if collinsGlass.contains(name) {
            return .collins
        }
        if fluteGlass.contains(name) {
            return .flute
        }
        if mugGlass.contains(name) {
            return .mug
        }
        if wineGlass.contains(name) {
            return .wine
        }
        if tikiGlass.contains(name) {
            return .tiki
        }
        if martiniGlass.contains(name) {
            return .martini
        }
        return .coupe
    }

    private static let rocksGlass: Set<String> = [
        "Americano", "Black Russian", "Boulevardier", "Caipirinha", "French Connection",
        "Negroni", "New York Sour", "Naked and Famous", "Old Fashioned", "Penicillin",
        "Rabo de Galo", "Remember the Maine", "Rusty Nail", "Sazerac", "Spritz",
        "Stinger", "Trinidad Sour", "Vieux Carré"
    ]

    private static let highballGlass: Set<String> = [
        "Cuba Libre", "Dark ‘N’ Stormy", "Fernandito", "Garibaldi", "Horse’s Neck",
        "Long Island Iced Tea", "Mojito", "Moscow Mule", "Paloma", "Planters Punch",
        "Suffering Bastard", "Tequila Sunrise"
    ]

    private static let collinsGlass: Set<String> = [
        "Bloody Mary", "Canchanchara", "Chartreuse Swizzle", "French 75", "Gin Fizz",
        "John Collins", "Ramos Fizz", "Sea Breeze", "Singapore Sling", "Tommy's Margarita"
    ]

    private static let fluteGlass: Set<String> = [
        "Bellini", "Champagne Cocktail", "Mimosa", "Russian Spring Punch"
    ]

    private static let mugGlass: Set<String> = [
        "Irish Coffee", "Mint Julep"
    ]

    private static let wineGlass: Set<String> = [
        "Aperol Spritz", "Kir", "Sherry Cobbler", "Ve.N.To"
    ]

    private static let tikiGlass: Set<String> = [
        "IBA Tiki", "Jungle Bird", "Mai-Tai", "Pina Colada", "Three Dots and a Dash", "Zombie"
    ]

    private static let martiniGlass: Set<String> = [
        "Aviation", "Casino", "Cosmopolitan", "Dry Martini", "Espresso Martini",
        "French Martini", "Grand Margarita", "Grasshopper", "Lemon Drop Martini",
        "Margarita", "Porn Star Martini", "Vesper"
    ]

    private static func layers(for name: String, category: DiscoverCategory) -> [DrinkLayer] {
        if let layers = drinkLayers[name] {
            return layers
        }

        switch category {
        case .all:
            return [.amber, .citrus, .clear]
        case .oldSchool:
            return [.deepAmber, .amber]
        case .classics:
            return [.citrus, .cream, .clear]
        case .house:
            return [.amber, .orange]
        }
    }

    private static let flavorProfiles: [String: String] = [:]

    private static let drinkDetails: [String: CocktailDetails] = [
        "Alexander": CocktailDetails(ingredients: ["30 ml Cognac", "30 ml Crème de Cacao (Brown)", "30 ml Fresh Cream"], method: "Pour all ingredients into cocktail shaker filled with ice cubes. Shake and strain into a chilled cocktail glass.", garnish: "Sprinkle fresh ground nutmeg on top."),
        "Americano": CocktailDetails(ingredients: ["30 ml Bitter Campari", "30 ml Sweet Red Vermouth", "A splash of Soda Water"], method: "Mix the ingredients directly in an old fashioned glass filled with ice cubes. Add a splash of Soda Water. Stir gently.", garnish: "Garnish with half orange slice and a lemon zest."),
        "Angel Face": CocktailDetails(ingredients: ["30 ml Gin", "30 ml Apricot Brandy", "30 ml Calvados"], method: "Pour all ingredients into cocktail shaker filled with ice cubes. Shake and strain into a chilled cocktail glass.", garnish: "No garnish listed."),
        "Aviation": CocktailDetails(ingredients: ["45 ml Gin", "15 ml Maraschino", "Luxardo", "15 ml Fresh Lemon Juice", "1 Bar Spoon Crème de Violette"], method: "Add all ingredients into a cocktail shaker. Shake with cracked ice and strain into a chilled cocktail glass.", garnish: "Optional Maraschino Cherry."),
        "Bee’s Knees": CocktailDetails(ingredients: ["52.5 ml Dry Gin", "2 teaspoons Honey Syrup", "22.5 ml Fresh Lemon Juice", "22.5 ml Fresh Orange Juice"], method: "Stir honey with lemon and orange juices until it dissolves, add gin and shake with ice. Strain into a chilled cocktail glass.", garnish: "Optionally garnish with a lemon or orange zest."),
        "Bellini": CocktailDetails(ingredients: ["100 ml Prosecco", "50 ml White Peach Puree"], method: "Pour peach puree into the mixing glass with ice, add the Prosecco wine. Stir gently and pour in a chilled flute glass. NOTE: Puccini – Fresh Mandarin Orange Juice; Rossini – Fresh Strawberry Puree; Tintoretto – Fresh Pomegranate Juice.", garnish: "No garnish listed."),
        "Between the Sheets": CocktailDetails(ingredients: ["30 ml White Rum", "30 ml Cognac", "30 ml Triple Sec", "20 ml Fresh Lemon Juice"], method: "Add all ingredients into a cocktail shaker. Shake with ice and strain into a chilled cocktail glass.", garnish: "No garnish listed."),
        "Black Russian": CocktailDetails(ingredients: ["50 ml Vodka", "20 ml Coffee Liqueur"], method: "Pour the ingredients into the old fashioned glass filled with ice cubes. Stir gently. strain ingredients into old fashioned glass filled with ice. NOTE: WHITE RUSSIAN – Float fresh cream on the top and stir in slowly.", garnish: "No garnish listed."),
        "Bloody Mary": CocktailDetails(ingredients: ["45 ml Vodka", "90 ml Tomato Juice", "15 ml Fresh Lemon Juice", "2 dashes Worcestershire Sauce", "Tabasco, Celery Salt, Pepper (Up to taste)"], method: "Stir gently all the ingredients in a mixing glass with ice, pour into rocks glass. NOTE: If requested served with ice, pour into highball glass.", garnish: "Celery, lemon wedge (Optional)."),
        "Boulevardier": CocktailDetails(ingredients: ["45 ml Bourbon or Rye Whiskey", "30 ml Bitter Campari", "30 ml Sweet Red Vermouth"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled cocktail glass.", garnish: "Garnish with a orange zest, optionally a lemon zest."),
        "Bramble": CocktailDetails(ingredients: ["50 ml Gin", "25 ml Fresh Lemon Juice", "12.5 ml Sugar Syrup", "15 ml Crème de Mûre"], method: "Pour all ingredients into cocktail shaker except the Crème de Mûre, shake well with ice, strain into chilled old fashioned glass filled with crushed ice, then pour the blackberry liqueur (Crème de Mûre) over the top of the drink, in a circular motion.", garnish: "Garnish optionally with a lemon slice and blackberries."),
        "Brandy Crusta": CocktailDetails(ingredients: ["52.5 ml Brandy", "7.5 ml Maraschino", "Luxardo", "1 Bar Spoon Curacao", "15 ml Fresh Lemon Juice", "1 Bar Spoon Simple Syrup", "2 Dashes Aromatic Bitters"], method: "Mix together all ingredients with ice cubes in a mixing glass and strain into a prepared slim cocktail glass.", garnish: "Rub a slice of orange (or lemon) around the rim of the glass and dip it in pulverized white sugar, so that the sugar will adhere to the edge of the glass. Carefully curling place the orange/lemon peel around the inside of the glass."),
        "Caipirinha": CocktailDetails(ingredients: ["60 ml Cachaça", "1 Lime cut into small wedges", "4 Teaspoons White Cane Sugar"], method: "Place lime and sugar into a double old fashioned glass and muddle gently. Fill the glass with cracked ice and add Cachaça. Stir gently to involve ingredients. Note: Caipiroska – Instead of Cachaça use Vodka; Caipirissima – Instead of Cachaça use Rum. Caipirão – Instead of Cachaça use Licor Beirão.", garnish: "No garnish listed."),
        "Canchanchara": CocktailDetails(ingredients: ["60 ml Cuban Aguardiente", "15 ml Fresh Lime Juice", "15 ml Raw Honey", "50 ml Water"], method: "Mix honey with water and lime juice and spread the mixture on the bottom and sides of the glass. Add cracked ice, and then the rum. End by energetically stirring from bottom to top.", garnish: "Garnish with a lime wedge."),
        "Cardinale": CocktailDetails(ingredients: ["40 ml Gin", "20 ml Dry Vermouth", "10 ml Bitter Campari"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled cocktail glass.", garnish: "Garnish with a lemon zest."),
        "Casino": CocktailDetails(ingredients: ["40 ml Old Tom Gin", "10 ml Maraschino", "Luxardo", "10 ml Fresh Lemon Juice", "2 Dashes Orange Bitters"], method: "Pour all ingredients into cocktails shaker, shake well with ice, strain into chilled rocks glass with ice.", garnish: "Garnish with a lemon zest and a maraschino cherry."),
        "Champagne Cocktail": CocktailDetails(ingredients: ["90 ml Chilled Champagne", "10 ml Cognac", "2 dashes Angostura bitters", "Few drops of Grand Marnier (optional)", "1 sugar cube"], method: "Place the sugar cube with 2 dashes of bitters in a large Champagne glass, add the cognac. Pour gently chilled Champagne.", garnish: "Garnish with orange zest and maraschino cherry."),
        "Chartreuse Swizzle": CocktailDetails(ingredients: ["45 ml Green Chartreuse", "30 ml Fresh Pineapple Juice", "22.5 ml Fresh Lime Juice", "15 ml Falernum"], method: "Pour all ingredients into a tall glass, add pebble ice. With the help of a swizzle stick (or cocktail spoon) mix vigorously, complete by filling the glass with more pebble ice.", garnish: "Garnish with mint leaves and grated nutmeg."),
        "Clover Club": CocktailDetails(ingredients: ["45 ml Gin", "15 ml Raspberry Syrup", "15 ml Fresh Lemon Juice", "Few Drops of Egg White"], method: "Pour all ingredients into cocktails shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "Fresh raspberries."),
        "Corpse Reviver #2": CocktailDetails(ingredients: ["30 ml Gin", "30 ml Cointreau", "30 ml Lillet Blanc", "30 ml Fresh Lemon Juice", "1 dash Absinthe"], method: "Pour all ingredients into shaker with ice. Shake well and strain in chilled cocktail glass.", garnish: "Garnish with an orange zest."),
        "Cosmopolitan": CocktailDetails(ingredients: ["40 ml Vodka Citron", "15 ml Cointreau", "15 ml Fresh Lime Juice", "30 ml Cranberry Juice"], method: "Add all ingredients into cocktail shaker filled with ice. Shake well and strain into large cocktail glass.", garnish: "Garnish with lemon twist."),
        "Cuba Libre": CocktailDetails(ingredients: ["50 ml White Rum", "120 ml Cola", "10 ml Fresh Lime Juice"], method: "Build all ingredients in a highball glass filled with ice.", garnish: "Garnish with lime wedge."),
        "Daiquiri": CocktailDetails(ingredients: ["60 ml White Cuban Ron", "20 ml Fresh Lime Juice", "2 Bar Spoons Superfine Sugar"], method: "In a cocktail shaker add all ingredients. Stir well to dissolve the sugar. Add ice and shake. Strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Dark ‘N’ Stormy": CocktailDetails(ingredients: ["60 ml Goslings Rum", "100 ml Ginger Beer"], method: "In a highball glass filled with ice pour the ginger beer and top floating with the Rum.", garnish: "Garnish with a lime wedge or slice."),
        "Don's Special Daiquiri": CocktailDetails(ingredients: ["30 ml Gold Jamaican Rum", "15 ml Cuban Rum", "15 ml Passion Fruit Syrup", "15 ml Fresh lime juice", "15 ml Honey Syrup"], method: "Blend for a few seconds in a milkshake mixer with crushed ice and pour into a footed copo glass. Fill the glass with more crushed ice.", garnish: "Garnish with 1/2 passion fruit"),
        "Dry Martini": CocktailDetails(ingredients: ["60 ml Gin", "10 ml Dry Vermouth"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled martini cocktail glass.", garnish: "Squeeze oil from lemon peel onto the drink, or garnish with a green olives if requested."),
        "Espresso Martini": CocktailDetails(ingredients: ["50 ml Vodka", "30 ml Kahlúa", "10 ml Sugar Syrup", "1 strong Espresso"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "3 coffee beans"),
        "Fernandito": CocktailDetails(ingredients: ["50 ml Fernet Branca", "Fill up with Cola"], method: "Pour the Fernet Branca into a double old fashioned glass with ice, fill the glass up with Cola. Gently stir.", garnish: "No garnish listed."),
        "French 75": CocktailDetails(ingredients: ["30 ml Gin", "15 ml Fresh Lemon Juice", "15 ml Sugar Syrup", "60 ml Champagne"], method: "Pour all the ingredients, except Champagne, into a shaker. Shake well and strain into a Champagne flute. Top up with Champagne. Stir gently.", garnish: "No garnish listed."),
        "French Connection": CocktailDetails(ingredients: ["35 ml Cognac", "35 ml Amaretto"], method: "Pour all ingredients directly into old fashioned glass filled with ice cubes. Stir gently.", garnish: "No garnish listed."),
        "French Martini": CocktailDetails(ingredients: ["45 ml Vodka", "15 ml Raspberry Liqueur", "15 ml Fresh Pineapple Juice"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "Squeeze oil from lemon peel onto the drink."),
        "Garibaldi": CocktailDetails(ingredients: ["45 ml Bitter Campari", "120 ml Freshly Squeezed Orange Juice"], method: "Build all ingredients in a highball glass filled with ice.", garnish: "Garnish with an orange wedge."),
        "Gin Basil Smash": CocktailDetails(ingredients: ["60ml Gin", "22.5 ml Freshly Squeezed Lemon Juice", "22.5 ml Sugar Syrup", "10 pcs Italian Basil leaves"], method: "Add all ingredients into shaker with ice. Shake vigorously and pour into chilled cocktail glass.", garnish: "No garnish listed."),
        "Gin Fizz": CocktailDetails(ingredients: ["45 ml Gin", "30 ml Fresh Lemon Juice", "10 ml Simple Syrup", "Splash of Soda Water"], method: "Shake all ingredients with ice except soda water. Pour into thin tall Tumbler glass , top with a splash soda water. NOTE: Serve without ice.", garnish: "Garnish with lemon slice, optional lemon zest."),
        "Grand Margarita": CocktailDetails(ingredients: ["45 ml Tequila 100% agave", "30 ml Grand Marnier", "15 ml Fresh Lime Juice"], method: "Rim the rock glass with good quality sea salt. Pour the ingredients into the shaker. Add ice to both glass and shaker. Shake hard for 10 seconds. Strain the drink into the glass.", garnish: "Garnish with a lime slice."),
        "Grasshopper": CocktailDetails(ingredients: ["20 ml Crème de Cacao (White)", "20 ml Crème de Menthe (Green)", "20 ml Fresh Cream"], method: "Pour all ingredients into shaker filled with ice. Shake briskly for few seconds. Strain into chilled cocktail glass.", garnish: "N/A, optional mint leave."),
        "Hanky Panky": CocktailDetails(ingredients: ["45 ml London Dry Gin", "45 ml Sweet Red Vermouth", "7.5 ml Fernet"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled cocktail glass.", garnish: "Orange zest."),
        "Hemingway Special": CocktailDetails(ingredients: ["60 ml Rum", "40 ml Grapefruit Juice", "15 ml Maraschino Luxardo", "15 ml Fresh Lime"], method: "Pour all ingredients into a shaker with ice. Shake well and strain into a large cocktail glass.", garnish: "No garnish listed."),
        "Horse’s Neck": CocktailDetails(ingredients: ["40 ml Cognac", "120 ml Ginger Ale", "Dash of Angostura Bitters (optional)"], method: "Pour Cognac and ginger ale directly into highball glass with ice cubes. Stir gently. If preferred, add dashes of Angostura Bitter.", garnish: "Garnish with rind of one lemon spiral."),
        "IBA Tiki": CocktailDetails(ingredients: ["30 ml Ron Profundo Havana Club", "30 ml Ron Smoky Havana Club", "15 ml Licor Amaretto", "5 ml Licor Frangelico", "5 drops Maraschino Luxardo", "30 ml Passion Fruit Puree", "90 Fresh Pineapple Juice", "30 Fresh Lime Juice", "1 pc Ginger Slice"], method: "In a cocktail shaker muddle a thin slice of Ginger, Pour all other ingredients. Shake vigorously with ice. Strain into a chilled Tiki glass filled with pebbled ice.", garnish: "Garnish with citruses and dehydrated pineapple slice."),
        "Illegal": CocktailDetails(ingredients: ["30 ml Espadin Mezcal", "15 ml Jamaica Overproof White Rum", "15 ml Falernum", "1 Bar Spoon Maraschino Luxardo", "22.5 ml Fresh Lime Juice", "15 ml Simple Syrup", "Few Drops of Egg White (Optional)"], method: "Pour all ingredients into the shaker. Shake vigorously with ice. Strain into a chilled cocktail glass, or “on the rocks” in a traditional clay or terracotta mug.", garnish: "No garnish listed."),
        "Irish Coffee": CocktailDetails(ingredients: ["50 ml Irish Whiskey", "120 ml Hot coffee", "50 ml Fresh cream (Chilled)", "1 teaspoon Sugar"], method: "Warm black coffee is poured into a preheated Irish coffee glass. Whiskey and at least one teaspoon of sugar is added and stirred until dissolved. Fresh thick chilled cream is carefully poured over the back of a spoon held just above the surface of the coffee. The layer of cream will float on the coffee without mixing. Plain sugar can be replaced with sugar syrup", garnish: "No garnish listed."),
        "John Collins": CocktailDetails(ingredients: ["45 ml Gin", "30 ml Fresh Lemon Juice", "15 ml Simple Syrup", "60 ml Soda Water"], method: "Pour all ingredients directly into highball filled with ice. Stir gently. NOTE: Use ‘Old Tom’ Gin for Tom Collins.", garnish: "Garnish with lemon slice and maraschino cherry."),
        "Jungle Bird": CocktailDetails(ingredients: ["45 ml Blackstrap rum", "22.5 ml Campari", "45 ml Pineapple juice", "15 ml Freshly Squeezed Lime juice", "15 ml Demerara sugar syrup"], method: "Pour all ingredients into a shaker with ice and shake. Strain into a rocks glass filled with ice.", garnish: "Garnish with a pineapple wedge."),
        "Kir": CocktailDetails(ingredients: ["90 ml Dry White Wine", "10 ml Crème de Cassis"], method: "Pour Crème de Cassis into glass, top up with white wine. NOTE: Kir Royal – Use Champagne instead of white wine", garnish: "No garnish listed."),
        "Last Word": CocktailDetails(ingredients: ["22.5 ml Gin", "22.5 ml Green Chartreuse", "22.5 ml Maraschino", "Luxardo", "22.5 ml Fresh Lime Juice"], method: "Add all ingredients into a cocktail shaker. Shake with ice and strain into a chilled cocktail glass.", garnish: "No garnish listed."),
        "Lemon Drop Martini": CocktailDetails(ingredients: ["30 ml Vodka", "20 ml Triple Sec", "15 ml Fresh Squeezed Lemon Juice"], method: "Pour all ingredients into a shaker with ice. Shake well and strain into a chilled cocktail glass.", garnish: "No garnish listed."),
        "Long Island Iced Tea": CocktailDetails(ingredients: ["15 ml Vodka", "15 ml Tequila", "15 ml White rum", "15 ml Gin", "15 ml Cointreau", "25 ml Lemon juice", "30 ml Simple syrup", "Top with Cola"], method: "Add all ingredients into highball glass filled with ice. Stir gently.", garnish: "Garnish with lemon slice (Optional)."),
        "Mai-Tai": CocktailDetails(ingredients: ["30 ml Amber Jamaican Rum", "30 ml Martinique Molasses Rhum*", "15 ml Orange Curacao", "15 ml Orgeat Syrup (Almond)", "30 ml Fresh Squeezed Lime Juice", "7.5 ml Simple Syrup"], method: "Add all ingredients into a shaker with ice. Shake and pour into a double rocks glass or an highball glass. * The Martinique molasses rum used by Trader Vic was not an Agricole Rhum but a type of “rummy” from molasses.", garnish: "Garnish with pineapple spear, mint leaves and lime peel."),
        "Manhattan": CocktailDetails(ingredients: ["50 ml Rye Whiskey", "20 ml Sweet Red Vermouth", "1 dash Angostura Bitters"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled cocktail glass.", garnish: "Garnish with cocktail cherry."),
        "Margarita": CocktailDetails(ingredients: ["50 ml Tequila 100% Agave", "20 ml Triple Sec", "15 ml Freshly Squeezed Lime Juice"], method: "Add all ingredients into a shaker with ice. Shake and strain into a chilled cocktail glass.", garnish: "Half salt rim (Optional)."),
        "Martinez": CocktailDetails(ingredients: ["45 ml London Dry Gin", "45 ml Sweet Red Vermouth", "1 Bar Spoon Maraschino", "Luxardo", "2 Dashes Orange Bitters"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled cocktail glass.", garnish: "Lemon zest."),
        "Mary Pickford": CocktailDetails(ingredients: ["45 ml White Rum", "45 ml Fresh Pineapple Juice", "7.5 ml Maraschino Luxardo", "5 ml Grenadine Syrup"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Mimosa": CocktailDetails(ingredients: ["75 ml Freshly Squeezed Orange Juice", "75 ml Prosecco"], method: "Pour orange juice into flute glass and gently pour the sparkling wine. Stir gently. NOTE: Also known as Buck’s Fizz.", garnish: "Garnish with orange twist (optional)."),
        "Mint Julep": CocktailDetails(ingredients: ["60 ml Bourbon Whiskey", "4 fresh Mint sprigs", "1 tsp Powdered Sugar", "2 tsp Water"], method: "In Julep Stainless Steel Cup gently muddle the mint with sugar and water. Fill the glass with cracked ice, add the Bourbon and stir well until the cup frosts.", garnish: "Garnish with a mint sprig."),
        "Missionary's Downfall": CocktailDetails(ingredients: ["30 ml White rum", "15 ml Peach Brandy", "15 ml Fresh lime juice", "30 ml Honey Mix", "10 pcs Mint Leaves", "3 to 4 pcs Pineapple Chunks"], method: "Blend all the ingredients with half cup of crushed ice. Serve it in a Coppa grande.", garnish: "Garnish with mint sprig and a slice of pineapple."),
        "Mojito": CocktailDetails(ingredients: ["45 ml White Cuban Ron", "20 ml Fresh Lime Juice", "6 pcs Mint Sprigs", "2 tsp White Cane Sugar", "Soda Water"], method: "Mix mint springs with sugar and lime juice. Add splash of soda water and fill the glass with ice. Pour the rum and top with soda water. Light stir to involve all ingredients.", garnish: "Garnish with sprigs of mint and slice of lime."),
        "Monkey Gland": CocktailDetails(ingredients: ["45 ml Dry Gin", "45 ml Fresh Orange Juice", "1 Tablespoon Absinthe", "1 Tablespoon Grenadine Syrup"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Moscow Mule": CocktailDetails(ingredients: ["45 ml Smirnoff Vodka", "120 ml Ginger Beer", "10 ml Fresh lime juice"], method: "In an Mule Cup or rocks glass, combine the vodka and ginger beer. Add lime juice and gently stir to involve all ingredients.", garnish: "Garnish with a lime slice."),
        "Naked and Famous": CocktailDetails(ingredients: ["22.5 ml Mezcal", "22.5 ml Yellow Chartreuse", "22.5 ml Aperol", "22.5 ml Fresh Lime Juice"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Negroni": CocktailDetails(ingredients: ["30 ml Gin", "30 ml Bitter Campari", "30 ml Sweet Red Vermouth"], method: "Pour all ingredients directly into chilled old fashioned glass filled with ice. Stir gently.", garnish: "Garnish with half orange slice."),
        "New York Sour": CocktailDetails(ingredients: ["60 ml Rye Whiskey or Bourbon", "22.5 ml Simple syrup", "30 ml Fresh lemon juice", "Few Drops of Egg White", "15 ml Red wine (Shiraz or Malbech)"], method: "Pour all ingredients into the shaker. Shake vigorously with ice. Strain into a chilled rocks glass filled with ice. Float the wine on top.", garnish: "Garnish with lemon or orange zest with cherry."),
        "Old Cuban": CocktailDetails(ingredients: ["6/8 pcs Mint Leaves", "45 ml Aged Rum", "22.5 ml Fresh Lime Juice", "30 ml Simple Syrup", "2 Dashes Angostura Bitters", "60 ml Brut Champagne or Prosecco"], method: "Pour all ingredients into cocktail shaker except the wine, shake well with ice, strain into chilled elegant cocktail glass. Top up with the sparkling wine.", garnish: "Garnish with mint springs."),
        "Old Fashioned": CocktailDetails(ingredients: ["45 ml Bourbon or Rye Whiskey", "1 Sugar Cube", "Few Dashes Angostura Bitters", "Few Dashes Plain Water"], method: "Place sugar cube in old fashioned glass and saturate with bitter, add few dashes of plain water. Muddle until dissolved. Fill the glass with ice cubes and add whiskey. Stir gently.", garnish: "Garnish with orange slice or zest, and a cocktail cherry."),
        "Paloma": CocktailDetails(ingredients: ["50 ml 100% Agave Tequila", "5 ml Fresh lime", "A pinch of Salt", "100 ml Pink Grapefruit Soda"], method: "Poor the tequila into a highball glass, squeeze the lime juice. Add ice and salt, fill up pink grapefruit soda. Stir gently.", garnish: "Garnish with a slice of lime."),
        "Paper Plane": CocktailDetails(ingredients: ["30 ml Bourbon Whiskey", "30 ml Amaro Nonino", "30 ml Aperol", "30 ml Fresh Lemon Juice"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Paradise": CocktailDetails(ingredients: ["30 ml Gin", "20 ml Apricot Brandy", "15 ml Fresh Orange Juice"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Penicillin": CocktailDetails(ingredients: ["60 ml Blended scotch whisky", "7.5 ml Lagavulin 16y", "22.5 ml Fresh lemon juice", "22.5 ml Honey syrup", "2-3 quarter size sliced fresh ginger"], method: "Muddle fresh ginger in a shaker and add the remaining ingredients except for the Islay single malt whisky. Fill the shaker with ice and shake. Fine train into a chilled Old Fashioned glass with ice. Float the single malt whisky on top.", garnish: "Garnish with candied ginger slices."),
        "Pina Colada": CocktailDetails(ingredients: ["50 ml White Rum", "30 ml Coconut Cream", "50 ml Fresh Pineapple Juice"], method: "Blend all the ingredients with ice in a electric blender, pour into a large glass and serve with straws. Note: Historically a few drops of fresh lime juice was added to taste. 4 slices of fresh pineapple can be used instead of juice", garnish: "Garnish with a slice of pineapple with a cocktail cherry."),
        "Pisco Punch": CocktailDetails(ingredients: ["60 ml Pisco", "22.5 ml Fresh Pineapple Juice", "15 ml Simple Syrup", "15 ml Fresh Lemon Juice", "30 ml Dry White Wine", "3 pcs Cloves"], method: "Gentle mash the simple syrup with the cloves, add the remaining ingredients except the wine. Shake vigorously and double strain into a large goblet. Add the wine on top and gently stir.", garnish: "No garnish listed."),
        "Pisco Sour": CocktailDetails(ingredients: ["60 ml Pisco", "30 ml Fresh Lemon Juice", "20 ml Simple Syrup", "1 Raw whole Egg White"], method: "Add all ingredients into a shaker with ice. Shake and strain into a chilled goblet glass.", garnish: "Few dashes of Amargo bitters on top as an aromatic garnish."),
        "Planters Punch": CocktailDetails(ingredients: ["45 ml Jamaican Rum", "15 ml Lime Juice", "30 ml Sugar Cane Juice"], method: "Pour all ingredients directly in a small tumbler or a typical terracotta glass. NOTE: Add dilution up to taste, it can be given by water, ice or fresh juices.", garnish: "Garnish with orange zest."),
        "Porn Star Martini": CocktailDetails(ingredients: ["50 ml Vanilla Vodka", "20 ml Passion Fruit Liqueur", "50 ml Passion Fruit Puree", "2 Bar Spoons Vanilla Sugar", "50 ml Champagne to serve on the side"], method: "Pour all ingredients into cocktail shaker, shake well with ice, double strain into a large chilled cocktail glass. Accompany with a shot of champagne.", garnish: "Garnish with passion fruit cup and sugar."),
        "Porto Flip": CocktailDetails(ingredients: ["15 ml Brandy", "45 ml Red Tawny Port Wine", "10 ml Egg Yolk"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "Sprinkle with fresh ground nutmeg."),
        "Rabo de Galo": CocktailDetails(ingredients: ["60 ml Cachaca", "20 ml Sweet Vermouth Cinzano Rosso", "15 ml Cynar", "2 Drops Angostura (Optional)"], method: "Combine all the ingredients into a rocks glass, add ice and stir briefly.", garnish: "Garnish with a orange twist."),
        "Ramos Fizz": CocktailDetails(ingredients: ["45 ml Gin", "15 ml Fresh Lime Juice", "15 ml Fresh Lemon Juice", "30 ml Sugar Syrup", "60 ml Cream", "30ml Egg white", "3 Dashes Orange Flower Water", "2 Drops Vanilla Extract", "Soda Water"], method: "Pour all ingredients except soda water in a cocktail shaker with ice. Shake for two minutes, double strain in a glass, pour the drink back in the shaker and hard shake without ice for one minute. Strain into a highball glass, top up with soda. NOTE: The drink was invented by Henry Ramos in 1888, at his bar Meyer’s Table d’Hôtel Internationale in New Orleans. The Ramos Fizz was originally shaken for 12 minutes by a crew of 30 bartenders who passed the shaker from one to another.", garnish: "No garnish listed."),
        "Remember the Maine": CocktailDetails(ingredients: ["60 ml Rye Whiskey", "22.5 ml Sweet Vermouth", "15 ml Cherry Brandy Luxardo", "7.5 ml Absinthe"], method: "Pour the absinthe into a coupe glass and swirl to completely coat the inside. Discard the absinthe and set the glass aside. Add the other ingredients to a mixing glass and fill it 3/4 full with ice. Stir until chilled, then strain into the glass rinsed with the absinthe.", garnish: "Garnish with lemon zest."),
        "Russian Spring Punch": CocktailDetails(ingredients: ["25 ml Vodka", "25 ml Fresh Lemon Juice", "15 ml Creme de Cassis", "10 ml Sugar Syrup", "Top up with Sparkling Wine"], method: "Pour all ingredients into cocktail shaker except the sparkling wine, shake well with ice, strain into chilled tall tumbler glass filled with ice and top up with sparkling wine.", garnish: "Garnish with blackberries and optionally a lemon slice as well."),
        "Rusty Nail": CocktailDetails(ingredients: ["45 ml Scotch Whisky", "25 ml Drambuie"], method: "Pour all ingredients directly into an old fashioned glass filled with ice. Stir gently.", garnish: "Garnish with lemon zest."),
        "Sazerac": CocktailDetails(ingredients: ["50 ml Cognac", "10 ml Absinthe", "1 Sugar Cube", "2 Dashes Peychaud’s Bitters"], method: "Rinse a chilled old-fashioned glass with the absinthe, add crushed ice and set it aside. Stir the remaining ingredients over ice in a mixing glass. Discard the ice and any excess absinthe from the prepared glass, strain the mixed drink into the glass. NOTE: The original recipe changed after the American Civil War, Rye Whiskey substituted Cognac as it became hard to obtain.", garnish: "Garnish with lemon zest."),
        "Sea Breeze": CocktailDetails(ingredients: ["40 ml Vodka", "120 ml Cranberry Juice", "30 ml Grapefruit Juice"], method: "Build all ingredients in a highball glass filled with ice.", garnish: "Garnish with an orange zest and cherry."),
        "Sex on the Beach": CocktailDetails(ingredients: ["40 ml Vodka", "20 ml Peach Schnapps", "40 ml Fresh Orange Juice", "40 ml Cranberry Juice"], method: "Build all ingredients in a highball glass filled with ice.", garnish: "Garnish with half orange slice."),
        "Sherry Cobbler": CocktailDetails(ingredients: ["45 ml Amontillado sherry", "45 ml Palo Cortado", "1 tsp Superfine Sugar (or granulated)", "1/2 Orange Wheel", "1/2 Lemon Wheel"], method: "Combine sherry, sugar and 2 quarter wheels each of orange and lemon in a shaker with ice, shake briskly, strain into a Julep cocktail cup filled with crushed ice.", garnish: "Garnish with fresh berries, ¼ wheel each orange and lemon. Serve with straws."),
        "Sidecar": CocktailDetails(ingredients: ["50 ml Cognac", "20 ml Triple Sec", "20 ml Fresh Lemon Juice"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Singapore Sling": CocktailDetails(ingredients: ["30 ml Gin", "15 ml Cherry Sangue Morlacco", "7.5 ml Cointreau", "7.5 ml DOM Bénédictine", "120 ml Fresh Pineapple Juice", "15 ml Fresh Lime Juice", "10 ml Grenadine Syrup", "A dash of Angostura bitters"], method: "Pour all ingredients into cocktail shaker filled with ice cubes. Shake well. Strain into Hurricane glass.", garnish: "Garnish with pineapple and maraschino cherry."),
        "South Side": CocktailDetails(ingredients: ["60 ml London dry Gin", "30 ml Fresh Lemon Juice", "15 ml Simple syrup", "5/6 Mint leaves", "Few drops Egg white (Optional)"], method: "Pour all ingredients into a cocktail shaker, shake well with ice, double-strain into chilled cocktail glass. Note: If egg white is used shake vigorously.", garnish: "Garnish with mint springs."),
        "Spicy Fifty": CocktailDetails(ingredients: ["50 ml Vodka Vanilla", "15 ml Elderflower Cordial", "15 ml Fresh Lime Juice", "10 ml Monin Honey Syrup", "2 thin Slices Red Chili Pepper"], method: "Pour all ingredients into a cocktail shaker, shake well with ice, double-strain into chilled cocktail glass.", garnish: "Garnish with a red chili pepper."),
        "Spritz": CocktailDetails(ingredients: ["90 ml Prosecco", "60 ml Aperol", "Splash of Soda water"], method: "Build all ingredients into a wine glass filled with ice. Stir gently. NOTE: There are other versions of the Spritz that use Campari, Cynar or Select instead of Aperol.", garnish: "Garnish with a slice of orange."),
        "Stinger": CocktailDetails(ingredients: ["50 ml Cognac", "20 ml White Crème de Menthe"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled martini cocktail glass.", garnish: "Optional mint leave."),
        "Suffering Bastard": CocktailDetails(ingredients: ["30 ml Cognac or Brandy", "30 ml Gin", "15 ml Fresh Lime Juice", "2 Dashes Angostura Bitters", "Top up Ginger beer"], method: "Pour all ingredients into cocktail shaker except the ginger beer, shake well with ice. Pour unstrained into a Collins glass or in the original. S. Bastard mug and top up with ginger beer.", garnish: "Garnish with mint spring and optionally an orange slice as well."),
        "Tequila Sunrise": CocktailDetails(ingredients: ["45 ml Tequila", "90 ml Fresh Orange Juice", "15 ml Grenadine Syrup"], method: "Pour tequila and orange juice directly into highball glass filled with ice cubes. Add the grenadine syrup to create chromatic effect (sunrise), do not stir.", garnish: "Garnish with half orange slice or an orange zest."),
        "Three Dots and a Dash": CocktailDetails(ingredients: ["45 ml Rhum Martinique Agricole", "15 ml Blended Aged Rum", "7.5 ml Falernum", "7.5 ml Allspice Saint Elizabeth15 ml Fresh Lime Juice", "15 ml Fresh Orange juice", "15 ml Honey Syrup", "2 Dashes Angostura Bitters"], method: "Pour all ingredients in a Blender with 12 ounces of crushed ice, flash blend, pour the drink into a footed copo glass. Fill the glass with more crushed ice.", garnish: "Garnish with three cherries and a rectangular chunk of pineapple."),
        "Tipperary": CocktailDetails(ingredients: ["50 ml Irish Whiskey", "25 ml Sweet Red Vermouth", "15 ml Green Chartreuse", "2 Dashes Angostura Bitters"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled martini cocktail glass.", garnish: "Garnish with a slice of orange."),
        "Tommy's Margarita": CocktailDetails(ingredients: ["60 ml Tequila 100% agave", "30 ml Fresh Lime Juice", "30 ml Agave Nectar"], method: "Pour all ingredients into a cocktail shaker, shake well with ice, strain into chilled rocks glass filled with ice.", garnish: "Garnish with a lime slice."),
        "Trinidad Sour": CocktailDetails(ingredients: ["45 ml Angostura Bitters", "30 ml Orgeat Syrup", "22.5 ml Fresh Lemon Juice", "15 ml Rye Whiskey"], method: "Pour all ingredients into a cocktail shaker, shake well with ice. Strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Tuxedo": CocktailDetails(ingredients: ["30 ml Old Tom Gin", "30 ml Dry Vermouth", "1/2 Bar Spoon Maraschino Luxardo", "1/4 Bar Spoon of Absinthe", "3 Dashes Orange Bitters"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled martini cocktail glass.", garnish: "Garnish with cherry and lemon zest."),
        "Ve.N.To": CocktailDetails(ingredients: ["45 ml White Smooth Grappa", "22.5 ml Fresh lemon Juice", "15 ml Honey mix (replace water with chamomile)*", "15 ml Chamomile cordial", "Few Drops of Egg White (Optional)"], method: "Pour all ingredients into the shaker. Shake vigorously with ice. Strain into a chilled small tumbler glass filled with ice. NOTE: *If desired water can be replaced by chamomile infusion in the honey mix.", garnish: "Garnish with lemon zest and white grapes."),
        "Vesper": CocktailDetails(ingredients: ["45 ml Gin", "15 ml Vodka", "7.5 ml Lillet Blanc"], method: "Pour all ingredients into cocktail shaker filled with ice cubes. Shake and strain into a chilled cocktail glass.", garnish: "Garnish with lemon zest."),
        "Vieux Carré": CocktailDetails(ingredients: ["30 ml Rye Whiskey", "30 ml Cognac", "30 ml Sweet Vermouth", "1 Bar Spoon Bénédictine", "2 Dashes Peychaud’s Bitters"], method: "Pour all ingredients into mixing glass with ice cubes. Stir well. Strain into chilled cocktail glass.", garnish: "Garnish with orange zest and maraschino cherry."),
        "Whiskey Sour": CocktailDetails(ingredients: ["45 ml Bourbon Whiskey", "25 ml Fresh Lemon Juice", "20 ml Sugar Syrup", "Few Drops of Egg White (Optional)"], method: "Pour all ingredients into cocktail shaker filled with ice. Shake well. Strain into cobbler glass. If served “On the rocks”, strain ingredients into old fashioned glass filled with ice. NOTE: If egg white is used shake little harder to release and incorporate the foam from the egg white.", garnish: "Garnish with half orange slice and maraschino cherry, optionally use orange zest."),
        "White Lady": CocktailDetails(ingredients: ["40 ml Gin", "30 ml Triple Sec", "20 ml Fresh Lemon Juice"], method: "Pour all ingredients into cocktail shaker, shake well with ice, strain into chilled cocktail glass.", garnish: "No garnish listed."),
        "Zombie": CocktailDetails(ingredients: ["45 ml Jamaican dark rum", "45 ml Gold Puerto Rican rum", "30 ml Demerara Rum", "20 ml Fresh lime juice", "15 ml Falernum", "15 ml Donn’s Mix*", "1 tsp Grenadine syrup", "1 dash Angostura bitters", "6 drops Pernod"], method: "Add all ingredients into an electric blender with 170 grams of cracked ice. With pulse bottom blend for a few seconds. Serve in a tall tumbler glass. Note: *Donn’s Mix: 2 parts of fresh yellow grapefruit and 1 part of cinnamon syrup", garnish: "Garnish with mint leaves."),
    ]

    private static let drinkLayers: [String: [DrinkLayer]] = [
        "Alexander": [.cream, .cocoa, .brandy],
        "Americano": [.cola, .campari, .vermouth],
        "Angel Face": [.apricot, .brandy, .clear],
        "Aviation": [.violet, .cloud, .clear],
        "Between the Sheets": [.brandy, .citrus, .clear],
        "Boulevardier": [.vermouth, .campari, .bourbon],
        "Brandy Crusta": [.amber, .citrus, .sugar],
        "Casino": [.cherry, .citrus, .clear],
        "Clover Club": [.raspberry, .foam],
        "Daiquiri": [.lime, .white],
        "Dry Martini": [.olive, .clear],
        "Gin Fizz": [.foam, .citrus, .clear],
        "Hanky Panky": [.vermouth, .amber, .clear],
        "John Collins": [.citrus, .clear],
        "Last Word": [.chartreuse, .lime, .clear],
        "Manhattan": [.vermouth, .cherry, .bourbon],
        "Martinez": [.vermouth, .amber, .clear],
        "Mary Pickford": [.pineapple, .cherry, .clear],
        "Monkey Gland": [.orange, .grenadine, .clear],
        "Negroni": [.vermouth, .campari, .gin],
        "Old Fashioned": [.bourbon, .orange],
        "Paradise": [.apricot, .orange, .clear],
        "Planters Punch": [.darkRum, .grenadine, .citrus],
        "Porto Flip": [.rubyPort, .egg, .brandy],
        "Ramos Fizz": [.foam, .cream, .clear],
        "Remember the Maine": [.vermouth, .cherry, .whiskey],
        "Rusty Nail": [.honey, .whiskey],
        "Sazerac": [.amber, .anise, .whiskey],
        "Sidecar": [.brandy, .citrus, .sugar],
        "Stinger": [.cream, .mint, .brandy],
        "Tuxedo": [.olive, .anise, .clear],
        "Vieux Carré": [.vermouth, .amber, .whiskey],
        "Whiskey Sour": [.foam, .lemon, .whiskey],
        "White Lady": [.foam, .lemon, .clear],
        "Bellini": [.peach, .sparkling],
        "Black Russian": [.coffee, .clear],
        "Bloody Mary": [.tomato, .spice],
        "Caipirinha": [.limeBright, .clear],
        "Cardinale": [.campari, .vermouth, .clear],
        "Champagne Cocktail": [.sparkling, .bitters, .sugar],
        "Corpse Reviver #2": [.orange, .anise, .clear],
        "Cosmopolitan": [.cranberry, .citrus, .clear],
        "Cuba Libre": [.cola, .lime, .clear],
        "French 75": [.sparkling, .lemon, .clear],
        "French Connection": [.amaretto, .brandy],
        "Garibaldi": [.orange, .campari],
        "Grasshopper": [.mint, .cream, .cocoa],
        "Hemingway Special": [.grapefruit, .cherry, .clear],
        "Horse’s Neck": [.ginger, .brandy],
        "Irish Coffee": [.cream, .coffee, .whiskey],
        "Kir": [.berry, .white],
        "Lemon Drop Martini": [.lemon, .sugar, .clear],
        "Long Island Iced Tea": [.orange, .blue, .lime, .cola],
        "Mai-Tai": [.darkRum, .almond, .lime],
        "Margarita": [.limeBright, .cream],
        "Mimosa": [.orange, .sparkling],
        "Mint Julep": [.mint, .whiskey],
        "Mojito": [.mint, .lime, .clear],
        "Moscow Mule": [.ginger, .lime, .clear],
        "Pina Colada": [.cream, .pineapple, .clear],
        "Pisco Sour": [.foam, .lemon, .clear],
        "Rabo de Galo": [.vermouth, .darkAmber],
        "Sea Breeze": [.cranberry, .grapefruit, .clear],
        "Sex on the Beach": [.cranberry, .orange, .peach],
        "Singapore Sling": [.grenadine, .pineapple, .clear],
        "Tequila Sunrise": [.orange, .grenadine],
        "Vesper": [.lemon, .clear],
        "Zombie": [.darkRum, .orange, .grenadine],
        "Bee’s Knees": [.honey, .lemon, .clear],
        "Bramble": [.berry, .lemon, .clear],
        "Canchanchara": [.honey, .lime, .clear],
        "Chartreuse Swizzle": [.chartreuse, .pineapple, .lime],
        "Dark ‘N’ Stormy": [.cola, .ginger, .darkRum],
        "Don's Special Daiquiri": [.passion, .lime, .clear],
        "Espresso Martini": [.foam, .coffee, .black],
        "Fernandito": [.cola, .fernet],
        "French Martini": [.raspberry, .pineapple, .clear],
        "Gin Basil Smash": [.basil, .lime, .clear],
        "Grand Margarita": [.orange, .lime, .clear],
        "IBA Tiki": [.darkRum, .pineapple, .grenadine],
        "Illegal": [.smoke, .lime, .amber],
        "Jungle Bird": [.pineapple, .campari, .darkRum],
        "Missionary's Downfall": [.mint, .pineapple, .clear],
        "Naked and Famous": [.orange, .chartreuse, .amber],
        "New York Sour": [.redWine, .foam, .whiskey],
        "Old Cuban": [.sparkling, .mint, .darkRum],
        "Paloma": [.grapefruit, .lime, .clear],
        "Paper Plane": [.orange, .amaro, .bourbon],
        "Penicillin": [.honey, .ginger, .whiskey],
        "Pisco Punch": [.pineapple, .lemon, .clear],
        "Porn Star Martini": [.passion, .vanilla, .sparkling],
        "Russian Spring Punch": [.berry, .sparkling, .clear],
        "Sherry Cobbler": [.orange, .sherry, .berry],
        "South Side": [.mint, .lime, .clear],
        "Spicy Fifty": [.chili, .honey, .clear],
        "Spritz": [.orange, .sparkling],
        "Suffering Bastard": [.ginger, .lime, .brandy],
        "Three Dots and a Dash": [.darkRum, .honey, .orange],
        "Tipperary": [.chartreuse, .vermouth, .whiskey],
        "Tommy's Margarita": [.limeBright, .agave, .clear],
        "Trinidad Sour": [.bitters, .almond, .lemon],
        "Ve.N.To": [.honey, .lemon, .grappa]
    ]
}

private struct CocktailRowData: Identifiable {
    let id = UUID()
    let name: String
    var meta: String
    var status: String
    var statusColor: Color
    let layers: [DrinkLayer]
    var category: DiscoverCategory = .all
    var glassStyle: GlassStyle = .rocks
    var ingredients: [String] = []
    var method: String = "Prepare and serve according to the IBA specification."
    var garnish: String = "No garnish listed."
    var flavorProfile: String = "Balanced and expressive, with the drink's signature ingredients shaping the finish."
    var proportions: [CocktailProportion] = []
    var isUserCreated: Bool = false
    var customCategory: String?

    var ingredientRows: [IngredientLine] {
        ingredients.map(IngredientLine.init(rawValue:))
    }

    var methodSteps: [RecipeStep] {
        RecipeStep.steps(from: method)
    }

    var detailEyebrow: String {
        let categoryLabel = switch category {
        case .all:
            "IBA COCKTAIL"
        case .oldSchool:
            "OLD SCHOOL"
        case .classics:
            "CLASSIC"
        case .house:
            "HOUSE"
        }

        return "\(categoryLabel) • \(glassStyle.displayName)"
    }

    func matchesSearch(_ query: String) -> Bool {
        let normalizedQuery = query.normalizedForSearch
        guard !normalizedQuery.isEmpty else {
            return true
        }

        if name.normalizedForSearch.contains(normalizedQuery) {
            return true
        }

        return ingredientRows.contains { ingredient in
            ingredient.name.normalizedForSearch.contains(normalizedQuery)
                || ingredient.amount.normalizedForSearch.contains(normalizedQuery)
        } || ingredients.contains { ingredient in
            ingredient.normalizedForSearch.contains(normalizedQuery)
        }
    }

    var requiredBarIngredients: [BarIngredient] {
        var ingredientsByKey: [String: BarIngredient] = [:]

        for ingredient in ingredientRows {
            let key = ingredient.name.barIngredientKey
            guard !key.isEmpty, ingredientsByKey[key] == nil else {
                continue
            }

            let color = proportions
                .first { IngredientLine(rawValue: $0.name).name.barIngredientKey == key }?
                .layer.color ?? layers.first?.color ?? AppTheme.quiet

            ingredientsByKey[key] = BarIngredient(
                key: key,
                name: BarIngredient.displayName(for: key, fallback: ingredient.name),
                color: color
            )
        }

        return ingredientsByKey.values.sorted { $0.name < $1.name }
    }

    func missingIngredients(from onHand: Set<String>) -> [BarIngredient] {
        requiredBarIngredients.filter { !onHand.contains($0.key) }
    }
}

private struct IngredientLine: Identifiable {
    let id = UUID()
    let name: String
    let amount: String

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = trimmed.firstMatch(pattern: #"^(\d+(?:\.\d+)?)\s*ml\s+(.+)$"#) {
            self.amount = IngredientLine.normalizedAmount(match[1])
            self.name = IngredientLine.cleanedName(match[2])
            return
        }

        if let match = trimmed.firstMatch(pattern: #"^(\d+(?:\.\d+)?/\d+(?:\.\d+)?|\d+/\d+)\s+(?:bar spoon|bar spoons)\s+(.+)$"#) {
            self.amount = "\(match[1]) Bar Spoon"
            self.name = IngredientLine.cleanedName(match[2])
            return
        }

        if let match = trimmed.firstMatch(pattern: #"^(\d+(?:\.\d+)?/\d+(?:\.\d+)?|\d+/\d+)\s+(.+)$"#) {
            self.amount = match[1]
            self.name = IngredientLine.cleanedName(match[2])
            return
        }

        if let match = trimmed.firstMatch(pattern: #"^(\d+(?:\.\d+)?)\s+(tsp|teaspoon|teaspoons|bar spoon|bar spoons|dash|dashes|drop|drops|pc|pcs|tablespoon|tablespoons)\s+(.+)$"#) {
            self.amount = "\(match[1]) \(match[2])"
            self.name = IngredientLine.cleanedName(match[3])
            return
        }

        if let match = trimmed.firstMatch(pattern: #"^(\d+(?:\.\d+)?)\s+(raw whole)\s+(.+)$"#) {
            self.amount = "\(match[1]) \(match[2])"
            self.name = IngredientLine.cleanedName(match[3])
            return
        }

        if let match = trimmed.firstMatch(pattern: #"^(Few drops|Few Drops|A dash|Dash|Few dashes|Few Dashes|2 dashes|2 Dashes|3 Dashes|A splash|Splash|Top with|Top up with|Fill up with|A pinch of|A pinch Of)\s+(.+)$"#) {
            self.amount = match[1]
            self.name = IngredientLine.cleanedName(match[2])
            return
        }

        self.amount = ""
        self.name = IngredientLine.cleanedName(trimmed)
    }

    private static func normalizedAmount(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            let formatted = number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : trimmed
            return "\(formatted)ml"
        }
        return trimmed
    }

    private static func cleanedName(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: #"(?i)^\s*of\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+\(optional\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RecipeStep: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    let body: String

    static func steps(from method: String) -> [RecipeStep] {
        let cleaned = method
            .replacingOccurrences(of: #"(?i)\s+NOTE:.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+Note:.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sentences = cleaned
            .split(separator: ".")
            .flatMap { splitCompoundInstructions(String($0)) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let source = sentences.isEmpty ? [cleaned] : sentences
        return source.enumerated().map { index, sentence in
            RecipeStep(number: index + 1, title: title(for: sentence), body: body(for: sentence))
        }
    }

    private static func splitCompoundInstructions(_ sentence: String) -> [String] {
        sentence
            .replacingOccurrences(
                of: #",\s+(?=(?:then\s+)?(?:strain|stir|build|top|pour|discard|fill|garnish)\b)"#,
                with: ". ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s+and\s+(?=(?:then\s+)?(?:strain|stir|build|top|pour|discard|fill|garnish)\b)"#,
                with: ". ",
                options: [.regularExpression, .caseInsensitive]
            )
            .split(separator: ".")
            .map { capitalizeFirst(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func capitalizeFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func title(for sentence: String) -> String {
        let lower = sentence.lowercased()
        if lower.contains("rim") {
            return "Prepare the glass"
        }
        if lower.contains("muddle") {
            return "Muddle"
        }
        if lower.contains("blend") {
            return "Blend"
        }
        if lower.contains("shake") && lower.contains("strain") {
            return "Shake and strain"
        }
        if lower.contains("shake") {
            return "Shake"
        }
        if lower.contains("stir") {
            return "Stir"
        }
        if lower.contains("strain") {
            return "Strain"
        }
        if lower.contains("top") || lower.contains("fill up") {
            return "Top up"
        }
        if lower.contains("build") || lower.contains("add all ingredients") || lower.contains("pour all ingredients") {
            return "Build"
        }
        if lower.contains("pour") {
            return "Pour"
        }
        if lower.contains("discard") {
            return "Discard"
        }
        return "Prepare"
    }

    private static func body(for sentence: String) -> String {
        var copy = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        copy = copy.replacingOccurrences(of: #"(?i)^poor "#, with: "Pour ", options: .regularExpression)
        copy = copy.replacingOccurrences(of: #"(?i)^strain ingredients"#, with: "Strain ingredients", options: .regularExpression)
        if !copy.hasSuffix(".") {
            copy += "."
        }
        return copy
    }
}

private struct CocktailDetails {
    let ingredients: [String]
    let method: String
    let garnish: String
}

private struct CocktailProportion: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double
    let layer: DrinkLayer
}

private struct ProportionsBar: View {
    let items: [CocktailProportion]

    private var total: Double {
        max(items.reduce(0) { $0 + $1.amount }, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(items) { item in
                    item.layer.color
                        .frame(width: proxy.size.width * item.amount / total)
                }
            }
        }
    }

}

private struct RecipeStepRow: View {
    let step: RecipeStep

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(format: "%02d", step.number))
                .appBody(size: 12, weight: .semibold, color: AppTheme.gold, lineHeight: 16)
                .lineLimit(1)
                .frame(minWidth: 16, minHeight: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .appBody(size: 15, weight: .semibold, color: AppTheme.text, lineHeight: 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.body)
                    .appBody(size: 13, color: AppTheme.muted, lineHeight: 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum GlassStyle: CaseIterable, Identifiable {
    case rocks, highball, collins, coupe, martini, flute, mug, wine, tiki

    var id: String { displayName }

    var displayName: String {
        switch self {
        case .rocks:
            "Rocks"
        case .highball:
            "Highball"
        case .collins:
            "Collins"
        case .coupe:
            "Coupe"
        case .martini:
            "Martini"
        case .flute:
            "Flute"
        case .mug:
            "Mug"
        case .wine:
            "Wine"
        case .tiki:
            "Tiki"
        }
    }

    var detailCopy: String {
        switch self {
        case .rocks:
            "Served short over ice in a rocks glass"
        case .highball:
            "Served long over ice in a tall glass"
        case .collins:
            "Served long and sparkling in a Collins glass"
        case .coupe:
            "Served up in a coupe"
        case .martini:
            "Served up in a stemmed cocktail glass"
        case .flute:
            "Served sparkling in a flute"
        case .mug:
            "Served cold in a handled mug"
        case .wine:
            "Served over ice in a wine glass"
        case .tiki:
            "Served tall over crushed ice in a tropical glass"
        }
    }
}

private extension GlassStyle {
    var glassSpec: GlassSpec {
        switch self {
        case .rocks:
            GlassSpec(
                viewBox: CGSize(width: 120, height: 120),
                displaySize: CGSize(width: 160, height: 160),
                fillPercent: 0.78,
                strokeWidth: 6.3,
                vessel: [
                    .move(8, 8), .line(112, 8), .line(108, 104),
                    .quad(96, 113, 107, 113), .line(24, 113),
                    .quad(12, 104, 13, 113), .close
                ],
                stem: [],
                extraOutline: [],
                shadow: [.ellipse(60, 116, 48, 5)],
                surface: [.ellipse(60, 32.96, 38.4, 1.56)]
            )
        case .highball:
            GlassSpec(
                viewBox: CGSize(width: 88, height: 230),
                displaySize: CGSize(width: 91.83, height: 240),
                fillPercent: 0.78,
                strokeWidth: 6.3,
                vessel: [
                    .move(8, 4), .line(80, 4), .line(76, 218),
                    .curve(12, 218, 75, 226, 13, 226), .close
                ],
                stem: [],
                extraOutline: [],
                shadow: [.ellipse(44, 228, 34, 4.5)],
                surface: [.ellipse(44, 56.32, 28.16, 2.99)]
            )
        case .collins:
            GlassSpec(
                viewBox: CGSize(width: 74, height: 252),
                displaySize: CGSize(width: 70.48, height: 240),
                fillPercent: 0.78,
                strokeWidth: 5.25,
                vessel: [
                    .move(6, 4), .line(68, 4), .line(65, 240),
                    .curve(9, 240, 64, 248, 10, 248), .close
                ],
                stem: [],
                extraOutline: [],
                shadow: [.ellipse(37, 250, 28, 4)],
                surface: [.ellipse(37, 61.6, 23.68, 3.28)]
            )
        case .coupe:
            GlassSpec(
                viewBox: CGSize(width: 130, height: 162),
                displaySize: CGSize(width: 160, height: 199.38),
                fillPercent: 0.78,
                strokeWidth: 5.78,
                vessel: [
                    .move(8, 8), .line(122, 8),
                    .curve(72, 84, 128, 44, 104, 80),
                    .line(58, 84),
                    .curve(8, 8, 26, 80, 2, 44),
                    .close
                ],
                stem: [
                    .move(59, 83), .line(59, 134), .line(40, 144),
                    .line(90, 144), .line(72, 134), .line(72, 83), .close
                ],
                extraOutline: [],
                shadow: [.ellipse(65, 148, 40, 5)],
                surface: [.ellipse(65, 26, 41.6, 2.11)]
            )
        case .martini:
            GlassSpec(
                viewBox: CGSize(width: 132, height: 152),
                displaySize: CGSize(width: 160, height: 184.24),
                fillPercent: 0.78,
                strokeWidth: 6.3,
                vessel: [
                    .move(4, 6), .line(128, 6), .line(71, 82),
                    .line(61, 82), .close
                ],
                stem: [
                    .move(62, 81), .line(62, 124), .line(44, 134),
                    .line(88, 134), .line(71, 124), .line(71, 81), .close
                ],
                extraOutline: [],
                shadow: [.ellipse(66, 138, 38, 5)],
                surface: [.ellipse(66, 24.24, 42.24, 1.98)]
            )
        case .flute:
            GlassSpec(
                viewBox: CGSize(width: 100, height: 260),
                displaySize: CGSize(width: 92.31, height: 240),
                fillPercent: 0.78,
                strokeWidth: 5.25,
                vessel: [
                    .move(36, 4), .line(64, 4),
                    .curve(72, 14, 70, 4, 73, 8),
                    .line(58, 196),
                    .curve(50, 204, 57, 202, 54, 204),
                    .curve(42, 196, 46, 204, 43, 202),
                    .line(28, 14),
                    .curve(36, 4, 27, 8, 30, 4),
                    .close
                ],
                stem: [
                    .move(43, 203), .line(43, 242), .line(32, 250),
                    .line(68, 250), .line(57, 242), .line(57, 203), .close
                ],
                extraOutline: [],
                shadow: [.ellipse(50, 254, 28, 4)],
                surface: [.ellipse(50, 51.52, 32, 3.38)]
            )
        case .mug:
            GlassSpec(
                viewBox: CGSize(width: 144, height: 158),
                displaySize: CGSize(width: 160, height: 175.56),
                fillPercent: 0.78,
                strokeWidth: 6.3,
                vessel: [
                    .move(10, 8), .line(106, 8), .line(104, 142),
                    .quad(94, 150, 103, 150), .line(22, 150),
                    .quad(12, 142, 13, 150), .close
                ],
                stem: [],
                extraOutline: [
                    .move(106, 34),
                    .curve(146, 72, 132, 34, 146, 50),
                    .curve(106, 110, 146, 94, 132, 110),
                    .line(108, 96),
                    .curve(132, 72, 124, 96, 132, 86),
                    .curve(108, 48, 132, 58, 124, 48),
                    .close
                ],
                shadow: [.ellipse(58, 155, 48, 5.5)],
                surface: [.ellipse(72, 41.6, 46.08, 2.05)]
            )
        case .wine:
            GlassSpec(
                viewBox: CGSize(width: 160, height: 240),
                displaySize: CGSize(width: 160, height: 240),
                fillPercent: 0.78,
                strokeWidth: 6.6,
                vessel: [
                    .move(52.57, 6.86), .line(107.43, 6.86),
                    .curve(156.50, 73.14, 146.29, 6.86, 158.79, 36.57),
                    .curve(102.86, 132.57, 154.21, 105.14, 134.86, 125.71),
                    .line(57.14, 132.57),
                    .curve(3.50, 73.14, 25.14, 125.71, 5.79, 105.14),
                    .curve(52.57, 6.86, 1.21, 36.57, 13.71, 6.86),
                    .close
                ],
                stem: [
                    .move(59.43, 131.43), .line(59.43, 194.29), .line(38.86, 205.71),
                    .line(121.14, 205.71), .line(102.86, 194.29), .line(102.86, 131.43), .close
                ],
                extraOutline: [],
                shadow: [.ellipse(70, 184, 50, 5.5)],
                surface: [.ellipse(80, 36.75, 51.2, 3.12)]
            )
        case .tiki:
            GlassSpec(
                viewBox: CGSize(width: 149.68, height: 240),
                displaySize: CGSize(width: 149.68, height: 240),
                fillPercent: 0.78,
                strokeWidth: 7.45,
                vessel: [
                    .move(18.06, 7.74), .line(131.61, 7.74),
                    .curve(141.94, 20.65, 139.35, 7.74, 144.52, 12.90),
                    .line(127.74, 82.58),
                    .curve(145.34, 116.13, 144.52, 92.90, 147.92, 105.81),
                    .curve(113.55, 139.35, 142.76, 129.03, 131.61, 136.77),
                    .line(36.13, 139.35),
                    .curve(5.34, 116.13, 18.06, 136.77, 7.92, 129.03),
                    .curve(21.94, 82.58, 2.76, 105.81, 5.16, 92.90),
                    .line(7.74, 20.65),
                    .curve(18.06, 7.74, 5.16, 12.90, 10.32, 7.74),
                    .close
                ],
                stem: [],
                extraOutline: [],
                shadow: [.ellipse(58, 175, 44, 5)],
                surface: [.ellipse(74.84, 39.02, 47.90, 3.12)]
            )
        }
    }
}

private enum DrinkLayer {
    case vermouth, campari, gin, lime, white, bourbon, orange, limeBright, cream, pale
    case clear, amber, deepAmber, darkAmber, whiskey, brandy, darkRum, rubyPort, sherry, grappa
    case citrus, lemon, grapefruit, pineapple, peach, apricot, passion, cranberry, raspberry, berry, cherry
    case cola, coffee, cocoa, tomato, ginger, honey, agave, vanilla, almond, amaretto, bitters
    case mint, basil, olive, anise, chartreuse, sparkling, sugar, egg, foam, grenadine
    case blue, violet, cloud, chili, spice, smoke, fernet, amaro, black, redWine, bright

    var color: Color {
        switch self {
        case .vermouth:
            Color(red: 0.478, green: 0.122, blue: 0.122)
        case .campari:
            Color(red: 0.765, green: 0.271, blue: 0.212)
        case .gin:
            Color(red: 0.851, green: 0.851, blue: 0.851)
        case .lime:
            Color(red: 0.780, green: 0.859, blue: 0.620)
        case .white:
            Color(red: 0.820, green: 0.820, blue: 0.820)
        case .bourbon:
            Color(red: 0.522, green: 0.251, blue: 0.102)
        case .orange:
            Color(red: 0.859, green: 0.561, blue: 0.239)
        case .limeBright:
            Color(red: 0.722, green: 0.831, blue: 0.451)
        case .cream:
            Color(red: 0.898, green: 0.898, blue: 0.820)
        case .pale:
            Color(red: 0.820, green: 0.820, blue: 0.859)
        case .clear:
            Color(red: 0.900, green: 0.900, blue: 0.880)
        case .amber:
            Color(red: 0.780, green: 0.510, blue: 0.210)
        case .deepAmber:
            Color(red: 0.600, green: 0.280, blue: 0.090)
        case .darkAmber:
            Color(red: 0.390, green: 0.180, blue: 0.070)
        case .whiskey:
            Color(red: 0.610, green: 0.300, blue: 0.100)
        case .brandy:
            Color(red: 0.620, green: 0.330, blue: 0.150)
        case .darkRum:
            Color(red: 0.240, green: 0.110, blue: 0.060)
        case .rubyPort:
            Color(red: 0.420, green: 0.070, blue: 0.120)
        case .sherry:
            Color(red: 0.700, green: 0.380, blue: 0.180)
        case .grappa:
            Color(red: 0.890, green: 0.860, blue: 0.730)
        case .citrus:
            Color(red: 0.930, green: 0.780, blue: 0.270)
        case .lemon:
            Color(red: 0.960, green: 0.860, blue: 0.300)
        case .grapefruit:
            Color(red: 0.930, green: 0.450, blue: 0.380)
        case .pineapple:
            Color(red: 0.930, green: 0.740, blue: 0.270)
        case .peach:
            Color(red: 0.930, green: 0.550, blue: 0.360)
        case .apricot:
            Color(red: 0.900, green: 0.490, blue: 0.210)
        case .passion:
            Color(red: 0.950, green: 0.620, blue: 0.120)
        case .cranberry:
            Color(red: 0.690, green: 0.090, blue: 0.180)
        case .raspberry:
            Color(red: 0.780, green: 0.220, blue: 0.350)
        case .berry:
            Color(red: 0.520, green: 0.080, blue: 0.260)
        case .cherry:
            Color(red: 0.640, green: 0.060, blue: 0.100)
        case .cola:
            Color(red: 0.150, green: 0.050, blue: 0.030)
        case .coffee:
            Color(red: 0.130, green: 0.080, blue: 0.050)
        case .cocoa:
            Color(red: 0.300, green: 0.170, blue: 0.110)
        case .tomato:
            Color(red: 0.710, green: 0.070, blue: 0.040)
        case .ginger:
            Color(red: 0.720, green: 0.520, blue: 0.270)
        case .honey:
            Color(red: 0.900, green: 0.620, blue: 0.180)
        case .agave:
            Color(red: 0.840, green: 0.720, blue: 0.420)
        case .vanilla:
            Color(red: 0.890, green: 0.760, blue: 0.520)
        case .almond:
            Color(red: 0.720, green: 0.600, blue: 0.430)
        case .amaretto:
            Color(red: 0.520, green: 0.260, blue: 0.090)
        case .bitters:
            Color(red: 0.540, green: 0.120, blue: 0.080)
        case .mint:
            Color(red: 0.330, green: 0.620, blue: 0.380)
        case .basil:
            Color(red: 0.150, green: 0.500, blue: 0.240)
        case .olive:
            Color(red: 0.520, green: 0.580, blue: 0.260)
        case .anise:
            Color(red: 0.850, green: 0.880, blue: 0.740)
        case .chartreuse:
            Color(red: 0.710, green: 0.820, blue: 0.250)
        case .sparkling:
            Color(red: 0.900, green: 0.820, blue: 0.540)
        case .sugar:
            Color(red: 0.940, green: 0.910, blue: 0.820)
        case .egg:
            Color(red: 0.920, green: 0.780, blue: 0.440)
        case .foam:
            Color(red: 0.940, green: 0.920, blue: 0.840)
        case .grenadine:
            Color(red: 0.770, green: 0.060, blue: 0.120)
        case .blue:
            Color(red: 0.400, green: 0.780, blue: 0.830)
        case .violet:
            Color(red: 0.500, green: 0.390, blue: 0.710)
        case .cloud:
            Color(red: 0.770, green: 0.820, blue: 0.860)
        case .chili:
            Color(red: 0.780, green: 0.090, blue: 0.060)
        case .spice:
            Color(red: 0.470, green: 0.120, blue: 0.060)
        case .smoke:
            Color(red: 0.360, green: 0.340, blue: 0.310)
        case .fernet:
            Color(red: 0.100, green: 0.060, blue: 0.040)
        case .amaro:
            Color(red: 0.430, green: 0.150, blue: 0.090)
        case .black:
            Color(red: 0.020, green: 0.018, blue: 0.015)
        case .redWine:
            Color(red: 0.460, green: 0.040, blue: 0.100)
        case .bright:
            Color(red: 0.820, green: 0.880, blue: 0.360)
        }
    }

    var title: String {
        switch self {
        case .vermouth:
            "Vermouth"
        case .campari:
            "Campari"
        case .gin:
            "Gin"
        case .lime, .limeBright:
            "Lime"
        case .white:
            "White spirit"
        case .bourbon:
            "Bourbon"
        case .orange:
            "Orange"
        case .cream:
            "Cream"
        case .pale:
            "Pale mixer"
        case .clear:
            "Clear spirit"
        case .amber, .deepAmber, .darkAmber:
            "Amber spirit"
        case .whiskey:
            "Whiskey"
        case .brandy:
            "Brandy"
        case .darkRum:
            "Dark rum"
        case .rubyPort:
            "Ruby port"
        case .sherry:
            "Sherry"
        case .grappa:
            "Grappa"
        case .citrus:
            "Citrus"
        case .lemon:
            "Lemon"
        case .grapefruit:
            "Grapefruit"
        case .pineapple:
            "Pineapple"
        case .peach:
            "Peach"
        case .apricot:
            "Apricot"
        case .passion:
            "Passion fruit"
        case .cranberry:
            "Cranberry"
        case .raspberry:
            "Raspberry"
        case .berry:
            "Berry"
        case .cherry:
            "Cherry"
        case .cola:
            "Cola"
        case .coffee:
            "Coffee"
        case .cocoa:
            "Cocoa"
        case .tomato:
            "Tomato"
        case .ginger:
            "Ginger"
        case .honey:
            "Honey"
        case .agave:
            "Agave"
        case .vanilla:
            "Vanilla"
        case .almond:
            "Almond"
        case .amaretto:
            "Amaretto"
        case .bitters:
            "Bitters"
        case .mint:
            "Mint"
        case .basil:
            "Basil"
        case .olive:
            "Olive"
        case .anise:
            "Anise"
        case .chartreuse:
            "Chartreuse"
        case .sparkling:
            "Sparkling wine"
        case .sugar:
            "Sugar"
        case .egg:
            "Egg"
        case .foam:
            "Foam"
        case .grenadine:
            "Grenadine"
        case .blue:
            "Blue curacao"
        case .violet:
            "Violet"
        case .cloud:
            "Cloudy citrus"
        case .chili:
            "Chili"
        case .spice:
            "Spice"
        case .smoke:
            "Smoke"
        case .fernet:
            "Fernet"
        case .amaro:
            "Amaro"
        case .black:
            "Dark liqueur"
        case .redWine:
            "Red wine"
        case .bright:
            "Bright citrus"
        }
    }

    var flavorNote: String {
        switch self {
        case .vermouth, .rubyPort, .sherry, .redWine:
            "winey"
        case .campari, .bitters, .amaro, .fernet:
            "bitter"
        case .gin, .anise, .olive:
            "botanical"
        case .lime, .limeBright, .lemon, .citrus, .grapefruit:
            "bright"
        case .white, .clear, .sparkling:
            "crisp"
        case .bourbon, .whiskey, .brandy, .darkRum, .amber, .deepAmber, .darkAmber, .grappa:
            "spirit-forward"
        case .orange, .peach, .apricot, .passion, .pineapple:
            "fruity"
        case .cream, .foam, .egg, .vanilla:
            "silky"
        case .cola, .coffee, .cocoa, .black:
            "dark"
        case .tomato, .spice, .chili, .smoke:
            "savory"
        case .ginger, .honey, .agave, .sugar, .almond, .amaretto:
            "rounded"
        case .mint, .basil, .chartreuse:
            "herbal"
        case .cranberry, .raspberry, .berry, .cherry, .grenadine:
            "tart"
        case .blue, .violet, .cloud, .bright, .pale:
            "delicate"
        }
    }

    static func forIngredientKey(_ key: String) -> DrinkLayer {
        if key.contains("gin") { return .gin }
        if key.contains("vodka") || key.contains("white rum") { return .clear }
        if key.contains("rum") { return key.contains("dark") ? .darkRum : .amber }
        if key.contains("whiskey") || key.contains("whisky") || key.contains("bourbon") || key.contains("rye") || key.contains("scotch") { return .whiskey }
        if key.contains("cognac") || key.contains("brandy") || key.contains("calvados") { return .brandy }
        if key.contains("tequila") || key.contains("mezcal") { return .amber }
        if key.contains("vermouth") { return key.contains("dry") ? .clear : .vermouth }
        if key.contains("campari") || key.contains("aperol") { return .campari }
        if key.contains("lime") { return .limeBright }
        if key.contains("lemon") { return .lemon }
        if key.contains("orange") || key.contains("triple sec") || key.contains("cointreau") { return .orange }
        if key.contains("grapefruit") { return .grapefruit }
        if key.contains("pineapple") { return .pineapple }
        if key.contains("cranberry") { return .cranberry }
        if key.contains("grenadine") { return .grenadine }
        if key.contains("coffee") { return .coffee }
        if key.contains("cola") { return .cola }
        if key.contains("cream") || key.contains("egg") { return .cream }
        if key.contains("ginger") { return .ginger }
        if key.contains("honey") { return .honey }
        if key.contains("agave") { return .agave }
        if key.contains("sugar") { return .sugar }
        if key.contains("basil") { return .basil }
        if key.contains("mint") { return .mint }
        if key.contains("absinthe") || key.contains("pernod") { return .anise }
        if key.contains("salt") { return .white }
        return .amber
    }
}

private struct CocktailListRow: View {
    let cocktail: CocktailRowData

    var body: some View {
        HStack(spacing: 14) {
            MiniDiagram(layers: cocktail.layers)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(cocktail.name)
                    .appBody(size: 15, weight: .semibold, color: AppTheme.text, lineHeight: 19)
                    .lineLimit(1)
                Text(cocktail.meta)
                    .appBody(size: 12, color: AppTheme.muted, lineHeight: 16)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(cocktail.status)
                .appBody(size: 11, weight: .medium, color: cocktail.statusColor, lineHeight: 14)
                .frame(width: 54, alignment: .trailing)
        }
        .frame(height: 72)
        .padding(.horizontal, 14)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MiniDiagram: View {
    let layers: [DrinkLayer]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                layer.color
            }
        }
        .clipShape(Circle())
    }
}

private struct IngredientChip: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .appBody(size: 12, weight: .medium, color: AppTheme.muted, lineHeight: 16)
        }
        .frame(height: 34)
        .padding(.horizontal, 13)
        .background(AppTheme.surface)
        .clipShape(Capsule())
    }
}

private struct IngredientSuggestionRow: View {
    let ingredient: BarIngredient

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(ingredient.color)
                .frame(width: 10, height: 10)

            Text(ingredient.name)
                .appBody(size: 14, weight: .medium, color: AppTheme.text, lineHeight: 18)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.gold)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct BarIngredient: Identifiable, Hashable {
    let key: String
    let name: String
    let color: Color

    var id: String { key }

    static func == (lhs: BarIngredient, rhs: BarIngredient) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    static let availableIngredients: [BarIngredient] = {
        let cocktails = CocktailCatalog.cocktails(for: .all)
        var ingredientsByKey: [String: BarIngredient] = [:]

        for cocktail in cocktails {
            for ingredient in cocktail.ingredientRows {
                let key = ingredient.name.barIngredientKey
                guard !key.isEmpty else {
                    continue
                }

                if ingredientsByKey[key] == nil {
                    ingredientsByKey[key] = BarIngredient(
                        key: key,
                        name: displayName(for: key, fallback: ingredient.name),
                        color: color(for: ingredient, in: cocktail)
                    )
                }
            }
        }

        return ingredientsByKey.values.sorted { $0.name < $1.name }
    }()

    private static func color(for ingredient: IngredientLine, in cocktail: CocktailRowData) -> Color {
        if let proportion = cocktail.proportions.first(where: { IngredientLine(rawValue: $0.name).name.barIngredientKey == ingredient.name.barIngredientKey }) {
            return proportion.layer.color
        }

        return cocktail.layers.first?.color ?? AppTheme.quiet
    }

    fileprivate static func displayName(for key: String, fallback: String) -> String {
        let knownNames: [String: String] = [
            "absinthe": "Absinthe",
            "agave nectar": "Agave Nectar",
            "amaretto": "Amaretto",
            "angostura bitters": "Angostura Bitters",
            "aperol": "Aperol",
            "basil leaves": "Italian Basil Leaves",
            "brandy": "Brandy",
            "campari": "Campari",
            "champagne": "Champagne",
            "cloves": "Cloves",
            "cognac": "Cognac",
            "cola": "Cola",
            "coffee": "Coffee",
            "coffee liqueur": "Coffee Liqueur",
            "cointreau": "Cointreau",
            "cranberry juice": "Cranberry Juice",
            "dark rum": "Dark Rum",
            "dry vermouth": "Dry Vermouth",
            "egg white": "Egg White",
            "gin": "Gin",
            "ginger ale": "Ginger Ale",
            "ginger beer": "Ginger Beer",
            "ginger slice": "Ginger Slice",
            "grapefruit juice": "Grapefruit Juice",
            "grenadine": "Grenadine",
            "honey syrup": "Honey Syrup",
            "lemon juice": "Lemon Juice",
            "lime juice": "Lime Juice",
            "orange juice": "Orange Juice",
            "orgeat syrup": "Orgeat Syrup",
            "pernod": "Pernod",
            "pineapple juice": "Pineapple Juice",
            "prosecco": "Prosecco",
            "red chili pepper": "Red Chili Pepper",
            "rum": "Rum",
            "salt": "Salt",
            "soda water": "Soda Water",
            "sugar cube": "Sugar Cube",
            "sugar syrup": "Sugar Syrup",
            "sweet vermouth": "Sweet Vermouth",
            "tequila": "Tequila",
            "triple sec": "Triple Sec",
            "vanilla extract": "Vanilla Extract",
            "vodka": "Vodka",
            "whiskey": "Whiskey",
            "white rum": "White Rum"
        ]

        if let knownName = knownNames[key] {
            return knownName
        }

        return fallback
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct FormField: View {
    let label: String
    let value: String
    var height: CGFloat = 57

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(AppTheme.gold)
            Text(value)
                .appBody(size: 15, color: AppTheme.text, lineHeight: 20)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FormTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 57
    var axis: Axis = .horizontal
    var capitalization: TextInputAutocapitalization = .words
    var keyboardType: UIKeyboardType = .default
    var focused: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(AppTheme.gold)
            }
            TextField(placeholder, text: $text, axis: axis)
                .focused(focused ?? $internalFocus)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.text)
                .tint(AppTheme.gold)
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .lineLimit(axis == .vertical ? 2...4 : 1...1)
                .submitLabel(.done)
                .onSubmit {
                    if let focused {
                        focused.wrappedValue = false
                    } else {
                        internalFocus = false
                    }
                }
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DraftIngredient: Identifiable {
    let id = UUID()
    let ingredient: BarIngredient
    var amount = ""
    var measure = "ml"

    var ingredientLine: String {
        let trimmedAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAmount.isEmpty else {
            return ingredient.name
        }

        return "\(trimmedAmount) \(measure) \(ingredient.name)"
    }

    var proportionAmount: Double {
        Double(amount) ?? 1
    }
}

private let recipeMeasureOptions = [
    "ml", "dash", "dashes", "drop", "drops", "tsp", "teaspoon", "teaspoons",
    "bar spoon", "bar spoons", "pc", "pcs", "tablespoon", "tablespoons"
]

private struct GlassPickerField: View {
    @Binding var selectedGlass: GlassStyle?

    var body: some View {
        Menu {
            ForEach(GlassStyle.allCases) { glass in
                Button(glass.displayName) {
                    selectedGlass = glass
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GLASS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(AppTheme.gold)
                    Text(selectedGlass?.displayName ?? "Choose a glass")
                        .appBody(size: 15, color: selectedGlass == nil ? AppTheme.muted : AppTheme.text, lineHeight: 20)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.gold)
            }
            .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyRecipeCopy: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .appBody(size: 13, color: AppTheme.muted, lineHeight: 18)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 12)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecipeActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.gold)
                Text(title)
                    .appBody(size: 14, weight: .medium, color: AppTheme.text, lineHeight: 20)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppTheme.activeSurface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DraftStepRow: View {
    let number: Int
    let text: String
    let onDelete: () -> Void

    var body: some View {
        SwipeDeleteContainer(onDelete: onDelete) {
            HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .appBody(size: 12, weight: .semibold, color: AppTheme.gold, lineHeight: 16)
                .frame(width: 22, height: 22)
                .background(AppTheme.activeSurface)
                .clipShape(Circle())

            Text(text)
                .appBody(size: 14, color: AppTheme.text, lineHeight: 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct EditableIngredient: View {
    @Binding var ingredient: DraftIngredient
    let onDelete: () -> Void

    var body: some View {
        SwipeDeleteContainer(onDelete: onDelete) {
            HStack(alignment: .center, spacing: 12) {
            Text(ingredient.ingredient.name)
                .appBody(size: 14, color: AppTheme.text, lineHeight: 18)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()

            TextField("0", text: $ingredient.amount)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppTheme.text)
                .tint(AppTheme.gold)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .frame(width: 56, height: 42, alignment: .center)
                .onChange(of: ingredient.amount) { _, newValue in
                    ingredient.amount = newValue.filter(\.isNumber)
                }

            Menu {
                ForEach(recipeMeasureOptions, id: \.self) { measure in
                    Button(measure) {
                        ingredient.measure = measure
                    }
                }
            } label: {
                Text(ingredient.measure)
                    .appBody(size: 14, weight: .medium, color: AppTheme.text, lineHeight: 18)
                    .lineLimit(1)
                    .frame(width: 92, height: 42, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(AppTheme.activeSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            }
            .frame(minHeight: 60)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SwipeDeleteContainer<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: Content
    @State private var dragOffset: CGFloat = 0

    private let limit: CGFloat = 104
    private let deleteThreshold: CGFloat = 88

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.29, blue: 0.31))
                .overlay(alignment: dragOffset >= 0 ? .leading : .trailing) {
                    Image(systemName: "trash")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                }
                .opacity(abs(dragOffset) > 4 ? 1 : 0)

            content
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 14, coordinateSpace: .local)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragOffset = max(-limit, min(limit, value.translation.width))
                        }
                        .onEnded { value in
                            if abs(value.translation.width) > deleteThreshold, abs(value.translation.height) < 54 {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    dragOffset = value.translation.width < 0 ? -limit : limit
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    onDelete()
                                    dragOffset = 0
                                }
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct IngredientAmount: View {
    let name: String
    let amount: String

    var body: some View {
        HStack {
            Text(name)
                .appBody(size: 16, color: AppTheme.text, lineHeight: 20)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !amount.isEmpty {
                Text(amount)
                    .appBody(size: 16, color: AppTheme.muted, lineHeight: 20)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct BottomNav: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    navItems
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(height: 72)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .glassEffect(.regular.tint(Color.white.opacity(0.18)), in: .rect(cornerRadius: 36))
                }
            } else {
                navItems
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(height: 72)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var navItems: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tab == selectedTab ? AppTheme.gold : AppTheme.muted)
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tab == selectedTab ? AppTheme.text : AppTheme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 29, style: .continuous)
                            .fill(tab == selectedTab ? Color.white.opacity(0.12) : .clear)
                    )
                    .overlay {
                        if tab == selectedTab {
                            RoundedRectangle(cornerRadius: 29, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.text)
                .frame(width: 44, height: 44)
                .background(AppTheme.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.border))
        }
        .buttonStyle(.plain)
    }
}

private struct CocktailGlass: View {
    let layers: [DrinkLayer]
    var proportions: [CocktailProportion] = []
    let style: GlassStyle
    var scale: CGFloat = 1
    var swishProgress: CGFloat = 1

    var body: some View {
        ReferenceGlass(layers: layers, proportions: proportions, spec: style.glassSpec, scale: scale, swishProgress: swishProgress)
        .frame(width: 320 * scale, height: 360 * scale)
    }
}

private struct LayerStack: View {
    let layers: [DrinkLayer]
    let proportions: [CocktailProportion]

    private var measuredLayers: [(color: Color, amount: Double)] {
        if !proportions.isEmpty {
            return proportions.map { ($0.layer.color, max($0.amount, 0.1)) }
        }

        return layers.map { ($0.color, 1) }
    }

    private var total: Double {
        max(measuredLayers.reduce(0) { $0 + $1.amount }, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ForEach(Array(measuredLayers.enumerated()), id: \.offset) { _, layer in
                    layer.color
                        .frame(height: proxy.size.height * layer.amount / total)
                }
            }
        }
    }
}

private struct ReferenceGlass: View {
    let layers: [DrinkLayer]
    let proportions: [CocktailProportion]
    let spec: GlassSpec
    let scale: CGFloat
    let swishProgress: CGFloat

    var body: some View {
        let artScale = scale * 1.18
        let artSize = CGSize(width: spec.displaySize.width * artScale, height: spec.displaySize.height * artScale)

        ZStack {
            ReferenceShape(commands: spec.stem, viewBox: spec.viewBox)
                .fill(.black)
                .frame(width: artSize.width, height: artSize.height)

            ReferenceLiquid(layers: layers, proportions: proportions, spec: spec, swishProgress: swishProgress)
                .frame(width: artSize.width, height: artSize.height)

            LiquidSurface(spec: spec, color: surfaceColor, swishProgress: swishProgress)
                .frame(width: artSize.width, height: artSize.height)

            ReferenceShape(commands: spec.vessel, viewBox: spec.viewBox)
                .stroke(.black, style: StrokeStyle(lineWidth: spec.strokeWidth * artScale, lineCap: .round, lineJoin: .round))
                .frame(width: artSize.width, height: artSize.height)

            ReferenceShape(commands: spec.extraOutline, viewBox: spec.viewBox)
                .fill(.black)
                .frame(width: artSize.width, height: artSize.height)
        }
        .frame(width: artSize.width, height: artSize.height)
    }

    private var surfaceColor: Color {
        if let first = proportions.first {
            return first.layer.color
        }

        return layers.first?.color ?? .black
    }
}

private struct ReferenceLiquid: View {
    let layers: [DrinkLayer]
    let proportions: [CocktailProportion]
    let spec: GlassSpec
    let swishProgress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let topY = proxy.size.height * spec.surfaceCenterYRatio
            let bottomY = proxy.size.height * spec.vesselBottomYRatio
            let liquidHeight = max(1, bottomY - topY)
            LayerStack(layers: layers, proportions: proportions)
                .frame(width: proxy.size.width, height: liquidHeight)
                .offset(y: topY)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .mask(SwishLiquidShape(topYRatio: spec.surfaceCenterYRatio, bottomYRatio: spec.vesselBottomYRatio, progress: swishProgress))
                .clipShape(ReferenceShape(commands: spec.vessel, viewBox: spec.viewBox))
        }
    }
}

private struct LiquidSurface: View {
    let spec: GlassSpec
    let color: Color
    let swishProgress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let damping = pow(max(0, 1 - swishProgress), 0.72)
            let sway = sin((swishProgress * 6.8 + 0.25) * .pi)
            let y = proxy.size.height * spec.surfaceCenterYRatio + sway * proxy.size.height * 0.075 * damping
            Ellipse()
                .fill(color.opacity(0.72))
                .frame(
                    width: proxy.size.width * spec.surfaceWidthRatio * (1 + damping * 0.22),
                    height: max(2, proxy.size.height * spec.surfaceHeightRatio * (1 + damping * 0.55))
                )
                .position(x: proxy.size.width / 2, y: y)
                .rotationEffect(.degrees(Double(sway * damping * 10.5)))
                .clipShape(ReferenceShape(commands: spec.vessel, viewBox: spec.viewBox))
        }
    }
}

private struct SwishLiquidShape: Shape {
    let topYRatio: CGFloat
    let bottomYRatio: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let settledTop = rect.height * topYRatio
        let bottomY = rect.height * bottomYRatio
        let damping = pow(max(0, 1 - progress), 0.72)
        let wave = sin((progress * 6.8 + 0.25) * .pi) * rect.height * 0.24 * damping
        let lip = rect.height * 0.075 * damping

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: settledTop + wave))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: settledTop - wave * 0.45),
            control1: CGPoint(x: rect.minX + rect.width * 0.28, y: settledTop - wave - lip),
            control2: CGPoint(x: rect.minX + rect.width * 0.62, y: settledTop + wave + lip)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bottomY))
        path.addLine(to: CGPoint(x: rect.minX, y: bottomY))
        path.closeSubpath()
        return path
    }
}

private struct GlassSpec {
    let viewBox: CGSize
    let displaySize: CGSize
    let fillPercent: CGFloat
    let strokeWidth: CGFloat
    let vessel: [PathCommand]
    let stem: [PathCommand]
    let extraOutline: [PathCommand]
    let shadow: [PathCommand]
    let surface: [PathCommand]

    var liquidFillPercent: CGFloat {
        vesselBottomYRatio - surfaceCenterYRatio
    }

    var vesselBottomYRatio: CGFloat {
        let bottomY = vessel.flatMap(\.yValues).max() ?? viewBox.height
        return min(1, max(0, bottomY / viewBox.height))
    }

    var surfaceCenterYRatio: CGFloat {
        guard let ellipse = surface.first?.ellipseValues else {
            return 1 - fillPercent
        }
        return ellipse.cy / viewBox.height
    }

    var surfaceWidthRatio: CGFloat {
        guard let ellipse = surface.first?.ellipseValues else {
            return 0.64
        }
        return ellipse.rx * 2 / viewBox.width
    }

    var surfaceHeightRatio: CGFloat {
        guard let ellipse = surface.first?.ellipseValues else {
            return 0.018
        }
        return ellipse.ry * 2 / viewBox.height
    }
}

private enum PathCommand {
    case move(CGFloat, CGFloat)
    case line(CGFloat, CGFloat)
    case quad(CGFloat, CGFloat, CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case close
    case ellipse(CGFloat, CGFloat, CGFloat, CGFloat)

    var ellipseValues: (cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)? {
        guard case let .ellipse(cx, cy, rx, ry) = self else {
            return nil
        }
        return (cx, cy, rx, ry)
    }

    var yValues: [CGFloat] {
        switch self {
        case let .move(_, y), let .line(_, y):
            return [y]
        case let .quad(_, y, _, cy):
            return [y, cy]
        case let .curve(_, y, _, c1y, _, c2y):
            return [y, c1y, c2y]
        case let .ellipse(_, cy, _, ry):
            return [cy - ry, cy + ry]
        case .close:
            return []
        }
    }
}

private struct ReferenceShape: Shape {
    let commands: [PathCommand]
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        let transform = { (x: CGFloat, y: CGFloat) in
            CGPoint(x: rect.minX + x / viewBox.width * rect.width, y: rect.minY + y / viewBox.height * rect.height)
        }

        var path = Path()
        for command in commands {
            switch command {
            case let .move(x, y):
                path.move(to: transform(x, y))
            case let .line(x, y):
                path.addLine(to: transform(x, y))
            case let .quad(x, y, cx, cy):
                path.addQuadCurve(to: transform(x, y), control: transform(cx, cy))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                path.addCurve(to: transform(x, y), control1: transform(c1x, c1y), control2: transform(c2x, c2y))
            case .close:
                path.closeSubpath()
            case let .ellipse(cx, cy, rx, ry):
                path.addEllipse(in: CGRect(
                    x: rect.minX + (cx - rx) / viewBox.width * rect.width,
                    y: rect.minY + (cy - ry) / viewBox.height * rect.height,
                    width: (rx * 2) / viewBox.width * rect.width,
                    height: (ry * 2) / viewBox.height * rect.height
                ))
            }
        }
        return path
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                width = max(width, rowWidth - spacing)
                height += rowHeight + rowSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        width = max(width, rowWidth - spacing)
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension Text {
    func appBody(size: CGFloat, weight: Font.Weight = .regular, color: Color, lineHeight: CGFloat) -> some View {
        self
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(max(0, lineHeight - size))
    }
}

private extension View {
    func swipeRightToDelete(_ action: @escaping () -> Void) -> some View {
        gesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 90, abs(value.translation.height) < 50 {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            action()
                        }
                    }
                }
        )
    }
}

private extension String {
    var normalizedForSearch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var barIngredientKey: String {
        var text = normalizedForSearch
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9# ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = text
            .replacingOccurrences(of: "freshly squeezed ", with: "")
            .replacingOccurrences(of: "fresh squeezed ", with: "")
            .replacingOccurrences(of: "fresh ", with: "")
            .replacingOccurrences(of: "chilled ", with: "")
            .replacingOccurrences(of: "smooth ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.contains("absinthe") || text.contains("absinth") {
            return "absinthe"
        }
        if text.contains("egg white") {
            return "egg white"
        }
        if text == "salt" || text.contains(" salt") || text.contains("salt ") {
            return "salt"
        }
        if text.contains("sugar cube") {
            return "sugar cube"
        }
        if text.contains("italian basil") || text.contains("basil leaves") || text.contains("basil") {
            return "basil leaves"
        }
        if text.contains("vanilla extract") {
            return "vanilla extract"
        }
        if text.contains("red chili pepper") || text.contains("chili pepper") {
            return "red chili pepper"
        }
        if text.contains("cloves") || text == "clove" {
            return "cloves"
        }
        if text.contains("pernod") {
            return "pernod"
        }
        if text.contains("ginger slice") || text.contains("gengibre") {
            return "ginger slice"
        }
        if text.contains("angostura") {
            return "angostura bitters"
        }
        if text.contains("peychaud") {
            return "peychaud bitters"
        }
        if text.contains("orange bitters") {
            return "orange bitters"
        }
        if text.contains("bitters") {
            return "bitters"
        }
        if text.contains("soda water") || text == "soda" || text.contains("soda ") {
            return "soda water"
        }
        if text.contains("ginger beer") {
            return "ginger beer"
        }
        if text.contains("ginger ale") {
            return "ginger ale"
        }
        if text.contains("cola") {
            return "cola"
        }
        if text.contains("lime") {
            return "lime juice"
        }
        if text.contains("lemon") {
            return "lemon juice"
        }
        if text.contains("grapefruit") {
            return "grapefruit juice"
        }
        if text.contains("pineapple") {
            return "pineapple juice"
        }
        if text.contains("cranberry") {
            return "cranberry juice"
        }
        if text.contains("orange juice") || text.contains("mandarin") {
            return "orange juice"
        }
        if text.contains("campari") {
            return "campari"
        }
        if text.contains("aperol") {
            return "aperol"
        }
        if text.contains("cointreau") || text.contains("triple sec") || text.contains("curacao") {
            return "triple sec"
        }
        if text.contains("grand marnier") {
            return "grand marnier"
        }
        if text.contains("dry vermouth") {
            return "dry vermouth"
        }
        if text.contains("sweet") && text.contains("vermouth") || text.contains("red vermouth") {
            return "sweet vermouth"
        }
        if text.contains("vermouth") {
            return "vermouth"
        }
        if text.contains("gin") {
            return "gin"
        }
        if text.contains("vodka") {
            return "vodka"
        }
        if text.contains("tequila") {
            return "tequila"
        }
        if text.contains("mezcal") {
            return "mezcal"
        }
        if text.contains("white rum") || text.contains("white cuban ron") || text.contains("cuban ron") {
            return "white rum"
        }
        if text.contains("dark rum") || text.contains("blackstrap") || text.contains("aged rum") || text.contains("demerara rum") {
            return "dark rum"
        }
        if text.contains("rum") || text.contains("ron ") || text.contains("rhum") {
            return "rum"
        }
        if text.contains("whiskey") || text.contains("whisky") || text.contains("bourbon") || text.contains("rye") || text.contains("scotch") {
            return "whiskey"
        }
        if text.contains("cognac") {
            return "cognac"
        }
        if text.contains("brandy") || text.contains("calvados") {
            return "brandy"
        }
        if text.contains("prosecco") {
            return "prosecco"
        }
        if text.contains("champagne") || text.contains("sparkling wine") {
            return "champagne"
        }
        if text.contains("wine") {
            return text.contains("red") || text.contains("port") || text.contains("tawny") ? "red wine" : "white wine"
        }
        if text.contains("simple syrup") || text.contains("sugar syrup") {
            return "sugar syrup"
        }
        if text.contains("honey") {
            return "honey syrup"
        }
        if text.contains("agave") {
            return "agave nectar"
        }
        if text.contains("orgeat") || text.contains("almond") {
            return "orgeat syrup"
        }
        if text.contains("cream") || text.contains("coconut") {
            return text.contains("coconut") ? "coconut cream" : "cream"
        }
        if text.contains("kahl") {
            return "coffee liqueur"
        }
        if text.contains("coffee") || text.contains("espresso") {
            return "coffee"
        }
        if text.contains("grenadine") {
            return "grenadine"
        }
        if text.contains("maraschino") {
            return "maraschino"
        }
        if text.contains("chartreuse") {
            return text.contains("yellow") ? "yellow chartreuse" : "green chartreuse"
        }
        if text.contains("mint") || text.contains("menthe") {
            return "mint"
        }

        return text
    }

    func firstMatch(pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range) else {
            return nil
        }

        return (0..<match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            guard let stringRange = Range(range, in: self) else { return nil }
            return String(self[stringRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private extension AppTheme {
    enum LayerColor {
        static let gin = Color(red: 0.851, green: 0.851, blue: 0.851)
        static let campari = Color(red: 0.765, green: 0.271, blue: 0.212)
        static let vermouth = Color(red: 0.478, green: 0.122, blue: 0.122)
    }
}
