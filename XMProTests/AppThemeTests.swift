// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI
import XCTest
@testable import XMPro

@MainActor
final class AppThemeTests: XCTestCase {
    func testThemeNormalizationAndColorSchemes() {
        XCTAssertEqual(AppTheme.normalized(nil), .system)
        XCTAssertEqual(AppTheme.normalized("unknown"), .system)
        XCTAssertEqual(AppTheme.normalized("WARM_PAPER"), .warmPaper)
        XCTAssertEqual(AppTheme.normalized("midnight"), .midnight)

        XCTAssertNil(AppTheme.system.preferredColorScheme)
        XCTAssertEqual(AppTheme.light.preferredColorScheme, .light)
        XCTAssertEqual(AppTheme.warmPaper.preferredColorScheme, .light)
        XCTAssertEqual(AppTheme.dark.preferredColorScheme, .dark)
        XCTAssertEqual(AppTheme.midnight.preferredColorScheme, .dark)
        XCTAssertTrue(AppTheme.midnight.prefersHighContrast)
        XCTAssertFalse(AppTheme.light.prefersHighContrast)
    }

    func testThemeStorePersistsAcrossReloadWithoutOverwritingOtherSettings() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmpro-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try StateRepository.open(directory: dir)
        try await repo.transaction { doc in
            var settings = doc.settings
            settings["speed"] = 1.5
            try doc.setSettings(settings)
        }

        let store = ThemeStore(repository: repo)
        await store.load()
        XCTAssertEqual(store.theme, .system)

        await store.select(.warmPaper)
        XCTAssertEqual(store.theme, .warmPaper)
        await repo.close()

        let reopened = try StateRepository.open(directory: dir)
        let store2 = ThemeStore(repository: reopened)
        await store2.load()
        XCTAssertEqual(store2.theme, .warmPaper)

        let doc = await reopened.state()
        XCTAssertEqual((doc.settings["speed"] as? NSNumber)?.doubleValue, 1.5)
    }
}
