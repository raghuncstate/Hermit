import Foundation
import SwiftUI

struct AnsiLine: Identifiable {
    let id = UUID()
    var text: AttributedString
}

struct AnsiAttributedStringParser {
    struct Style {
        var foreground: Color?
        var background: Color?
        var bold = false
        var italic = false
        var underline = false
    }

    static func parseLines(_ input: String) -> [AnsiLine] {
        input
            .components(separatedBy: "\n")
            .map { AnsiLine(text: parse($0)) }
    }

    static func plainText(_ input: String) -> String {
        String(parse(input).characters)
    }

    static func parse(_ input: String) -> AttributedString {
        var output = AttributedString()
        var style = Style()
        var plainBuffer = ""
        var index = input.startIndex

        func flushPlainBuffer() {
            guard !plainBuffer.isEmpty else { return }
            var run = AttributedString(plainBuffer)
            apply(style, to: &run)
            output += run
            plainBuffer = ""
        }

        while index < input.endIndex {
            if input[index] == "\u{1B}" {
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "[" {
                    var cursor = input.index(after: next)
                    var code = ""
                    while cursor < input.endIndex {
                        let char = input[cursor]
                        if char == "m" {
                            flushPlainBuffer()
                            applySGR(code, to: &style)
                            index = input.index(after: cursor)
                            break
                        } else if char.isNumber || char == ";" {
                            code.append(char)
                            cursor = input.index(after: cursor)
                        } else {
                            plainBuffer.append(input[index])
                            index = input.index(after: index)
                            break
                        }
                    }

                    if cursor >= input.endIndex {
                        index = input.endIndex
                    }
                    continue
                }
            }

            plainBuffer.append(input[index])
            index = input.index(after: index)
        }

        flushPlainBuffer()
        return output
    }

    private static func apply(_ style: Style, to string: inout AttributedString) {
        if let foreground = style.foreground {
            string.foregroundColor = foreground
        }
        if let background = style.background {
            string.backgroundColor = background
        }
        var presentationIntent = InlinePresentationIntent()
        if style.bold {
            presentationIntent.insert(.stronglyEmphasized)
        }
        if style.italic {
            presentationIntent.insert(.emphasized)
        }
        if !presentationIntent.isEmpty {
            string.inlinePresentationIntent = presentationIntent
        }
        if style.underline {
            string.underlineStyle = .single
        }
    }

    private static func applySGR(_ code: String, to style: inout Style) {
        let values = code.isEmpty ? [0] : code.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0

        while index < values.count {
            let value = values[index]
            switch value {
            case 0:
                style = Style()
            case 1:
                style.bold = true
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 22:
                style.bold = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 30...37:
                style.foreground = ansiColor(value - 30, bright: false)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = ansiColor(value - 40, bright: false)
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = ansiColor(value - 90, bright: true)
            case 100...107:
                style.background = ansiColor(value - 100, bright: true)
            case 38, 48:
                let isForeground = value == 38
                guard index + 1 < values.count else { break }
                let mode = values[index + 1]
                if mode == 5, index + 2 < values.count {
                    let color = xtermColor(values[index + 2])
                    if isForeground {
                        style.foreground = color
                    } else {
                        style.background = color
                    }
                    index += 2
                } else if mode == 2, index + 4 < values.count {
                    let color = Color(
                        red: Double(clampColor(values[index + 2])) / 255.0,
                        green: Double(clampColor(values[index + 3])) / 255.0,
                        blue: Double(clampColor(values[index + 4])) / 255.0
                    )
                    if isForeground {
                        style.foreground = color
                    } else {
                        style.background = color
                    }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    private static func ansiColor(_ index: Int, bright: Bool) -> Color {
        let normal: [Color] = [
            .black,
            Color(red: 0.78, green: 0.19, blue: 0.18),
            Color(red: 0.22, green: 0.62, blue: 0.29),
            Color(red: 0.72, green: 0.53, blue: 0.04),
            Color(red: 0.22, green: 0.40, blue: 0.78),
            Color(red: 0.58, green: 0.32, blue: 0.70),
            Color(red: 0.13, green: 0.55, blue: 0.62),
            Color(red: 0.86, green: 0.86, blue: 0.86),
        ]
        let brightColors: [Color] = [
            Color(red: 0.38, green: 0.38, blue: 0.38),
            Color(red: 0.93, green: 0.27, blue: 0.25),
            Color(red: 0.30, green: 0.75, blue: 0.35),
            Color(red: 0.91, green: 0.72, blue: 0.23),
            Color(red: 0.32, green: 0.55, blue: 0.96),
            Color(red: 0.72, green: 0.45, blue: 0.84),
            Color(red: 0.26, green: 0.73, blue: 0.80),
            .white,
        ]
        return (bright ? brightColors : normal)[max(0, min(7, index))]
    }

    private static func xtermColor(_ value: Int) -> Color {
        let value = max(0, min(255, value))
        if value < 16 {
            return ansiColor(value % 8, bright: value >= 8)
        }

        if value >= 232 {
            let component = Double(8 + (value - 232) * 10) / 255.0
            return Color(red: component, green: component, blue: component)
        }

        let color = value - 16
        let red = color / 36
        let green = (color % 36) / 6
        let blue = color % 6
        return Color(
            red: cubeComponent(red),
            green: cubeComponent(green),
            blue: cubeComponent(blue)
        )
    }

    private static func cubeComponent(_ value: Int) -> Double {
        value == 0 ? 0 : Double(55 + value * 40) / 255.0
    }

    private static func clampColor(_ value: Int) -> Int {
        max(0, min(255, value))
    }
}
