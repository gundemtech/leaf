import SwiftUI

extension Color {
    static let leafBackground = Color("BrandCream")
    static let leafCard       = Color("BrandPaper")
    static let leafInk        = Color("BrandInk")
    static let leafMuted      = Color("BrandStone")
    static let leafAccent     = Color("BrandOlive")
    static let leafAccentDeep = Color("BrandMoss")
    static let leafSignal     = Color("BrandSignal")
}

extension ShapeStyle where Self == Color {
    static var leafBackground: Color { .leafBackground }
    static var leafCard:       Color { .leafCard }
    static var leafInk:        Color { .leafInk }
    static var leafMuted:      Color { .leafMuted }
    static var leafAccent:     Color { .leafAccent }
    static var leafAccentDeep: Color { .leafAccentDeep }
    static var leafSignal:     Color { .leafSignal }
}
