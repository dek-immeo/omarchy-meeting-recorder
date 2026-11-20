import SwiftUI

/// Semantic colours for the capture monitor, the player and the transcript.
struct RecorderPalette {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    var canvas: Color { dark ? Color(red: 0.10, green: 0.10, blue: 0.13) : Color(red: 0.98, green: 0.97, blue: 0.96) }
    var paper: Color { dark ? Color(red: 0.15, green: 0.14, blue: 0.18) : .white }
    var ink: Color { dark ? Color(red: 0.95, green: 0.93, blue: 0.97) : Color(red: 0.16, green: 0.14, blue: 0.19) }
    var accent: Color { dark ? Color(red: 0.76, green: 0.66, blue: 0.91) : Color(red: 0.39, green: 0.28, blue: 0.56) }
    var mic: Color { dark ? Color(red: 0.67, green: 0.75, blue: 0.97) : Color(red: 0.28, green: 0.40, blue: 0.66) }
    var system: Color { dark ? Color(red: 0.98, green: 0.73, blue: 0.60) : Color(red: 0.65, green: 0.33, blue: 0.20) }
}

extension View {
    @ViewBuilder
    func recorderButtonShape() -> some View {
        if #available(macOS 14, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }

    func recorderCard(_ palette: RecorderPalette, monitor: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: monitor ? 20 : 14, style: .continuous)
        return background {
            shape.fill(palette.paper)
            if monitor {
                shape.fill(LinearGradient(colors: [palette.accent.opacity(0.17), palette.accent.opacity(0.025)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay { shape.strokeBorder(palette.ink.opacity(0.11), lineWidth: 1) }
    }
}

let recorderHeading = Font.system(size: 29, weight: .medium, design: .serif)
