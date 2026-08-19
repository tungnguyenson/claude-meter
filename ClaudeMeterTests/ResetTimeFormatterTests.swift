//
//  ResetTimeFormatterTests.swift
//  ClaudeMeterTests
//
//  Copyright (c) 2026 puq.ai. All rights reserved.
//  Licensed under the MIT License. See LICENSE file.
//

import XCTest
import AppKit
@testable import ClaudeMeter

// MARK: - Fixtures

/// Builds an absolute instant from wall-clock components in a fixed time zone.
/// Never derive test dates from `Date()`: a "today" case written as `now + 600`
/// flips to tomorrow when the suite runs at 23:55, and `+ 86400` is not reliably
/// "tomorrow" across a DST transition.
private func makeDate(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int, _ minute: Int,
    in timeZone: TimeZone
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

private let london = TimeZone(identifier: "Europe/London")!
private let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

/// 2026-08-13 is a Thursday, 2026-08-14 a Friday.
private enum Fixture {
    static let todayMorning = makeDate(2026, 8, 13, 9, 0, in: london)
    static let todayAfternoon = makeDate(2026, 8, 13, 15, 30, in: london)
    static let tomorrowAfternoon = makeDate(2026, 8, 14, 15, 30, in: london)
    static let lateTonight = makeDate(2026, 8, 13, 23, 50, in: london)
    static let afterMidnight = makeDate(2026, 8, 14, 0, 30, in: london)
}

private func makeFormatter(
    _ localeIdentifier: String,
    timeZone: TimeZone = london
) -> ResetTimeFormatter {
    ResetTimeFormatter(locale: Locale(identifier: localeIdentifier), timeZone: timeZone)
}

// MARK: - ResetTimeFormatter

final class ResetTimeFormatterTests: XCTestCase {
    func test_label_resetLaterToday_24hLocale_returnsTimeOnly() {
        let formatter = makeFormatter("en_GB")

        let label = formatter.label(for: Fixture.todayAfternoon, now: Fixture.todayMorning)

        XCTAssertEqual(label, "15:30")
    }

    func test_label_resetLaterToday_12hLocale_returnsTimeOnly() {
        let formatter = makeFormatter("en_US")

        let label = formatter.label(for: Fixture.todayAfternoon, now: Fixture.todayMorning) ?? ""

        // en_US short time uses U+202F before "PM" on macOS 13+ (ICU 72), so
        // assert structurally rather than against a literal " PM".
        XCTAssertTrue(label.hasPrefix("3:30"), "today must not carry a weekday prefix, got \(label)")
        XCTAssertTrue(label.contains("PM"), "got \(label)")
    }

    func test_label_resetTomorrow_prefixesShortWeekday() {
        let formatter = makeFormatter("en_GB")

        let label = formatter.label(for: Fixture.tomorrowAfternoon, now: Fixture.todayMorning)

        XCTAssertEqual(label, "Fri 15:30")
    }

    func test_label_resetJustAfterMidnight_prefixesWeekday() {
        let formatter = makeFormatter("en_GB")

        let label = formatter.label(for: Fixture.afterMidnight, now: Fixture.lateTonight)

        XCTAssertEqual(label, "Fri 00:30")
    }

    func test_label_localizesWeekday() {
        let formatter = makeFormatter("de_DE")

        let label = formatter.label(for: Fixture.tomorrowAfternoon, now: Fixture.todayMorning) ?? ""

        // German abbreviates Friday as "Fr"/"Fr." depending on the CLDR version;
        // assert the prefix is localized rather than pinning the exact spelling.
        XCTAssertTrue(label.hasSuffix("15:30"), "got \(label)")
        XCTAssertTrue(label.hasPrefix("Fr"), "got \(label)")
        XCTAssertFalse(label.hasPrefix("Fri "), "weekday must be localized, got \(label)")
    }

    func test_label_respectsTimeZone() {
        let londonLabel = makeFormatter("en_GB", timeZone: london)
            .label(for: Fixture.todayAfternoon, now: Fixture.todayMorning)
        let saigonLabel = makeFormatter("en_GB", timeZone: saigon)
            .label(for: Fixture.todayAfternoon, now: Fixture.todayMorning)

        XCTAssertEqual(londonLabel, "15:30")
        XCTAssertEqual(saigonLabel, "21:30")
    }

    func test_label_missingResetTime_returnsNil() {
        XCTAssertNil(makeFormatter("en_GB").label(for: nil, now: Fixture.todayMorning))
    }

    func test_label_resetInThePast_returnsNil() {
        let formatter = makeFormatter("en_GB")
        let past = Fixture.todayMorning.addingTimeInterval(-1)

        XCTAssertNil(formatter.label(for: past, now: Fixture.todayMorning))
    }

    func test_label_resetExactlyNow_returnsNil() {
        let formatter = makeFormatter("en_GB")

        XCTAssertNil(formatter.label(for: Fixture.todayMorning, now: Fixture.todayMorning))
    }
}

// MARK: - MenuBarAppearance

final class MenuBarAppearanceTests: XCTestCase {
    /// The status bar button reports the vibrant appearances, not aqua — the
    /// menu bar is tinted from the wallpaper. Both pairs are covered so the
    /// real code path is the tested one.
    func test_labelColor_isFlattenedPerAppearance() throws {
        for name in [NSAppearance.Name.aqua, .vibrantLight] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertLessThan(
                MenuBarAppearance.labelColor(for: appearance).brightnessComponent, 0.5,
                "\(name.rawValue) must render a dark label"
            )
        }

        for name in [NSAppearance.Name.darkAqua, .vibrantDark] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertGreaterThan(
                MenuBarAppearance.labelColor(for: appearance).brightnessComponent, 0.5,
                "\(name.rawValue) must render a light label"
            )
        }
    }
}

// MARK: - DetailedModeStyle persistence

final class DetailedModeStylePersistenceTests: XCTestCase {
    func test_encodeDecode_roundTripsEveryStyle() throws {
        for style in DetailedModeStyle.allCases {
            var settings = AppSettings()
            settings.detailedModeStyle = style

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.detailedModeStyle, style)
        }
    }

    func test_decode_missingDetailedModeStyle_usesDefault() throws {
        // JSON persisted by a build that predates the setting.
        let json = Data(#"{"displayMode":"Detailed"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(decoded.detailedModeStyle, AppSettings().detailedModeStyle)
    }
}
