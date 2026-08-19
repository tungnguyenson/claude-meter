//
//  AppSettingsPersistenceTests.swift
//  ClaudeMeterTests
//
//  Copyright (c) 2026 puq.ai. All rights reserved.
//  Licensed under the MIT License. See LICENSE file.
//

import XCTest
@testable import ClaudeMeter

/// `AppSettings` declares an explicit `CodingKeys`, so a property added without
/// a matching case is silently neither encoded nor decoded — the setting then
/// reverts to its default on the next launch, with nothing failing loudly.
/// `detailedModeStyle` shipped that way once already.
final class AppSettingsPersistenceTests: XCTestCase {
    /// Every field set away from its default, so a missing `CodingKeys` case
    /// shows up as an inequality after a round trip.
    private func makeNonDefaultSettings() -> AppSettings {
        var settings = AppSettings()
        settings.displayMode = .iconOnly
        settings.detailedModeStyle = .resetTime
        settings.colorScheme = .dark
        settings.showInDock = true
        settings.showSonnetLimit = true
        settings.showDesignLimit = false
        settings.showExtraUsage = true
        settings.refreshInterval = 300
        settings.launchAtLogin = true
        settings.notifyAt = [50, 80]
        settings.notificationsEnabled = false
        settings.webSessionKey = "sk-test"
        settings.webOrganizationId = "org-test"
        return settings
    }

    func test_encodeDecode_roundTripsEverySetting() throws {
        let settings = makeNonDefaultSettings()

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    /// Guards the same gap from the other side: a field that is decoded but
    /// never encoded would round trip through JSON yet vanish from the blob.
    func test_encodedJSON_carriesEverySetting() throws {
        let settings = makeNonDefaultSettings()

        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let mirroredFields = Mirror(reflecting: settings).children.compactMap(\.label)
        for field in mirroredFields {
            XCTAssertNotNil(json[field], "\(field) is missing from the persisted settings")
        }
    }

    func test_decode_emptyBlob_keepsDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(decoded, AppSettings())
    }
}
