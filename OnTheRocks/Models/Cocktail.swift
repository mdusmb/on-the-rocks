import Foundation
import SwiftUI

struct Cocktail: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let style: String
    let glass: String
    let strength: Int
    let tint: CocktailTint
    let ingredients: [String]
    let method: String

    static let samples: [Cocktail] = [
        Cocktail(
            name: "Citrus Negroni",
            style: "Bitter aperitif",
            glass: "Rocks",
            strength: 4,
            tint: .coral,
            ingredients: ["Gin", "Campari", "Sweet vermouth", "Orange twist"],
            method: "Stir with ice until chilled, then strain over a large cube."
        ),
        Cocktail(
            name: "Garden Gimlet",
            style: "Fresh sour",
            glass: "Coupe",
            strength: 3,
            tint: .mint,
            ingredients: ["Gin", "Lime", "Basil syrup", "Cucumber"],
            method: "Shake hard with ice and fine-strain into a chilled coupe."
        ),
        Cocktail(
            name: "Midnight Old Fashioned",
            style: "Spirit forward",
            glass: "Rocks",
            strength: 5,
            tint: .amber,
            ingredients: ["Bourbon", "Demerara", "Aromatic bitters", "Orange oil"],
            method: "Build in the glass, stir slowly, and garnish with orange peel."
        ),
        Cocktail(
            name: "Pear Collins",
            style: "Tall sparkling",
            glass: "Highball",
            strength: 2,
            tint: .gold,
            ingredients: ["Vodka", "Pear", "Lemon", "Soda"],
            method: "Shake the base, pour over ice, and top with cold soda."
        )
    ]
}

enum CocktailTint {
    case coral
    case mint
    case amber
    case gold
}

extension CocktailTint {
    var color: Color {
        switch self {
        case .coral:
            Color(red: 0.84, green: 0.32, blue: 0.35)
        case .mint:
            Color(red: 0.19, green: 0.69, blue: 0.55)
        case .amber:
            Color(red: 0.78, green: 0.48, blue: 0.13)
        case .gold:
            Color(red: 0.95, green: 0.65, blue: 0.20)
        }
    }
}
