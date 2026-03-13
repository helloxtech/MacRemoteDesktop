import Foundation
import UIKit

enum KeyCodeMapper {
    // Returns (keyCode: Int, modifiers: [String]) for a given Character
    static func map(_ char: Character) -> (keyCode: Int, modifiers: [String])? {
        // Special keys
        switch char {
        case "\n", "\r": return (36, [])   // Return
        case "\t":        return (48, [])   // Tab
        case " ":         return (49, [])   // Space
        default: break
        }
        // Use the charMap
        if let entry = charMap[char] { return entry }
        return nil
    }

    static func specialKeyCode(for key: UIKey) -> Int? {
        switch key.keyCode {
        case .keyboardDeleteOrBackspace: return 51
        case .keyboardEscape:           return 53
        case .keyboardReturnOrEnter:    return 36
        case .keyboardTab:              return 48
        case .keyboardUpArrow:          return 126
        case .keyboardDownArrow:        return 125
        case .keyboardLeftArrow:        return 123
        case .keyboardRightArrow:       return 124
        case .keyboardF1:               return 122
        case .keyboardF2:               return 120
        case .keyboardF3:               return 99
        case .keyboardF4:               return 118
        case .keyboardF5:               return 96
        case .keyboardF6:               return 97
        case .keyboardF7:               return 98
        case .keyboardF8:               return 100
        case .keyboardF9:               return 101
        case .keyboardF10:              return 109
        case .keyboardF11:              return 103
        case .keyboardF12:              return 111
        default: return nil
        }
    }

    // (keyCode, modifiers) — shift modifier means the shifted version of the key
    private static let charMap: [Character: (Int, [String])] = [
        "a": (0, []),  "b": (11, []), "c": (8, []),  "d": (2, []),
        "e": (14, []), "f": (3, []),  "g": (5, []),  "h": (4, []),
        "i": (34, []), "j": (38, []), "k": (40, []), "l": (37, []),
        "m": (46, []), "n": (45, []), "o": (31, []), "p": (35, []),
        "q": (12, []), "r": (15, []), "s": (1, []),  "t": (17, []),
        "u": (32, []), "v": (9, []),  "w": (13, []), "x": (7, []),
        "y": (16, []), "z": (6, []),
        "A": (0, ["shift"]),  "B": (11, ["shift"]), "C": (8, ["shift"]),
        "D": (2, ["shift"]),  "E": (14, ["shift"]), "F": (3, ["shift"]),
        "G": (5, ["shift"]),  "H": (4, ["shift"]),  "I": (34, ["shift"]),
        "J": (38, ["shift"]), "K": (40, ["shift"]), "L": (37, ["shift"]),
        "M": (46, ["shift"]), "N": (45, ["shift"]), "O": (31, ["shift"]),
        "P": (35, ["shift"]), "Q": (12, ["shift"]), "R": (15, ["shift"]),
        "S": (1, ["shift"]),  "T": (17, ["shift"]), "U": (32, ["shift"]),
        "V": (9, ["shift"]),  "W": (13, ["shift"]), "X": (7, ["shift"]),
        "Y": (16, ["shift"]), "Z": (6, ["shift"]),
        "0": (29, []), "1": (18, []), "2": (19, []), "3": (20, []),
        "4": (21, []), "5": (23, []), "6": (22, []), "7": (26, []),
        "8": (28, []), "9": (25, []),
        ")": (29, ["shift"]), "!": (18, ["shift"]), "@": (19, ["shift"]),
        "#": (20, ["shift"]), "$": (21, ["shift"]), "%": (23, ["shift"]),
        "^": (22, ["shift"]), "&": (26, ["shift"]), "*": (28, ["shift"]),
        "(": (25, ["shift"]),
        "-": (27, []),  "=": (24, []),  "[": (33, []),  "]": (30, []),
        "\\": (42, []), ";": (41, []),  "'": (39, []),  ",": (43, []),
        ".": (47, []),  "/": (44, []),
        "_": (27, ["shift"]), "+": (24, ["shift"]), "{": (33, ["shift"]),
        "}": (30, ["shift"]), "|": (42, ["shift"]), ":": (41, ["shift"]),
        "\"": (39, ["shift"]), "<": (43, ["shift"]), ">": (47, ["shift"]),
        "?": (44, ["shift"]), "~": (50, ["shift"]), "`": (50, []),
    ]
}
