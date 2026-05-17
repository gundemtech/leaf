//
//  LeafPrimitive.swift
//  Track 2 / D1 — Tier 1 raw colour scales. Internal-only: T2 token files
//  resolve T1 to semantic intent. UI code must never reference LeafPrimitive
//  directly (enforced by review + by the fact that T2 covers every concrete need).
//

import SwiftUI

enum LeafPrimitive {
    enum Green {
        static let _50 = Color(red: 0xF0 / 255, green: 0xFD / 255, blue: 0xF4 / 255)
        static let _100 = Color(red: 0xDC / 255, green: 0xFC / 255, blue: 0xE7 / 255)
        static let _200 = Color(red: 0xBB / 255, green: 0xF7 / 255, blue: 0xD0 / 255)
        static let _300 = Color(red: 0x86 / 255, green: 0xEF / 255, blue: 0xAC / 255)
        static let _400 = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
        static let _500 = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)  // anchor
        static let _600 = Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255)
        static let _700 = Color(red: 0x15 / 255, green: 0x80 / 255, blue: 0x3D / 255)
        static let _800 = Color(red: 0x16 / 255, green: 0x65 / 255, blue: 0x34 / 255)
        static let _900 = Color(red: 0x14 / 255, green: 0x53 / 255, blue: 0x2D / 255)
        static let _950 = Color(red: 0x05 / 255, green: 0x2E / 255, blue: 0x16 / 255)
    }

    enum Gray {
        static let _50 = Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xF9 / 255)
        static let _100 = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF4 / 255)
        static let _200 = Color(red: 0xE7 / 255, green: 0xE5 / 255, blue: 0xE4 / 255)
        static let _300 = Color(red: 0xD6 / 255, green: 0xD3 / 255, blue: 0xD1 / 255)
        static let _400 = Color(red: 0xA8 / 255, green: 0xA2 / 255, blue: 0x9E / 255)
        static let _500 = Color(red: 0x78 / 255, green: 0x71 / 255, blue: 0x6C / 255)
        static let _600 = Color(red: 0x57 / 255, green: 0x53 / 255, blue: 0x4E / 255)
        static let _700 = Color(red: 0x44 / 255, green: 0x40 / 255, blue: 0x3C / 255)
        static let _800 = Color(red: 0x29 / 255, green: 0x25 / 255, blue: 0x24 / 255)
        static let _900 = Color(red: 0x1C / 255, green: 0x19 / 255, blue: 0x17 / 255)
        static let _950 = Color(red: 0x0C / 255, green: 0x0A / 255, blue: 0x09 / 255)
    }

    enum Slate {
        static let _50 = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF7 / 255)
        static let _200 = Color(red: 0xC8 / 255, green: 0xC8 / 255, blue: 0xD0 / 255)
        static let _300 = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xAB / 255)
        static let _400 = Color(red: 0x7E / 255, green: 0x7E / 255, blue: 0x89 / 255)
        static let _500 = Color(red: 0x59 / 255, green: 0x59 / 255, blue: 0x62 / 255)
        static let _600 = Color(red: 0x3F / 255, green: 0x3F / 255, blue: 0x47 / 255)
        static let _700 = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x30 / 255)
        static let _800 = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x22 / 255)
        static let _900 = Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255)
        static let _950 = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)
    }

    enum Amber {
        static let _500 = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
        static let _600 = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x06 / 255)
    }

    enum Red {
        static let _500 = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
        static let _600 = Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255)
    }

    enum Blue {
        static let _500 = Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
        static let _600 = Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
    }
}
