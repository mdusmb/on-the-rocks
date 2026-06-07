import SwiftUI

struct CocktailDetailView: View {
    let cocktail: Cocktail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ingredients
                method
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(cocktail.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(cocktail.tint.color.gradient)
                .frame(height: 180)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cocktail.name)
                            .font(.largeTitle.bold())
                        Text("\(cocktail.style) • \(cocktail.glass)")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .padding()
                }

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { index in
                    Image(systemName: index <= cocktail.strength ? "circle.fill" : "circle")
                        .foregroundStyle(index <= cocktail.strength ? cocktail.tint.color : .secondary)
                        .accessibilityHidden(true)
                }
                Text("Strength")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ingredients: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ingredients")
                .font(.title2.bold())
            ForEach(cocktail.ingredients, id: \.self) { ingredient in
                Label(ingredient, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary, cocktail.tint.color)
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Method")
                .font(.title2.bold())
            Text(cocktail.method)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
