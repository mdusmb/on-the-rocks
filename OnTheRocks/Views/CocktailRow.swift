import SwiftUI

struct CocktailRow: View {
    let cocktail: Cocktail

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(cocktail.tint.color)
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "wineglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(cocktail.name)
                    .font(.headline)
                Text(cocktail.style)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
