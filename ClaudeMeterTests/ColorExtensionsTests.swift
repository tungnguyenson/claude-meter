//
//  ColorExtensionsTests.swift
//  ClaudeMeterTests
//
//  Copyright (c) 2026 puq.ai. All rights reserved.
//  Licensed under the MIT License. See LICENSE file.
//

import XCTest
import SwiftUI
import AppKit
@testable import ClaudeMeter

// MARK: - Color.hexString

final class ColorHexStringTests: XCTestCase {
    func test_hexString_forGrayscaleColor_returnsValidHex() {
        // NSColor(white:alpha:) lives in a grayscale color space whose cgColor
        // has only 2 components. The pre-fix code indexed [2] and crashed.
        let white = Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
        let black = Color(nsColor: NSColor(white: 0.0, alpha: 1.0))

        XCTAssertEqual(white.hexString, "#FFFFFF")
        XCTAssertEqual(black.hexString, "#000000")
    }
}
