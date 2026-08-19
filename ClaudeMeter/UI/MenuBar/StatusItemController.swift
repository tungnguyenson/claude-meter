//
//  StatusItemController.swift
//  ClaudeMeter
//
//  Copyright (c) 2026 puq.ai. All rights reserved.
//  Licensed under the MIT License. See LICENSE file.
//

import Cocoa
import SwiftUI
import Combine

enum MenuBarCountdownFormatter {
    enum Units {
        case hoursMinutes  // e.g. "3h 42m", "59m", "4h"
        case daysHours     // e.g. "3d 5h", "23h", "26m"
    }

    static func label(remaining: TimeInterval, units: Units) -> String? {
        guard remaining > 0 else { return nil }

        let totalMinutes = Int(remaining / 60)
        switch units {
        case .hoursMinutes:
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours == 0 { return "\(minutes)m" }
            if minutes == 0 { return "\(hours)h" }
            return "\(hours)h \(minutes)m"
        case .daysHours:
            if totalMinutes < 60 { return "\(totalMinutes)m" }

            let totalHours = totalMinutes / 60
            let days = totalHours / 24
            let hours = totalHours % 24
            if days == 0 { return "\(hours)h" }
            if hours == 0 { return "\(days)d" }
            return "\(days)d \(hours)h"
        }
    }
}

@MainActor
class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    // Progress icon configuration
    private let iconSize: CGFloat = 18

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupStatusItem()
        setupPopover()
        setupSubscriptions()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            if let image = NSImage(named: "AppLogo") {
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
            observeAppearanceChanges(button: button)
        }
    }

    /// The menu bar redraws only on a poll tick, and its colors are resolved
    /// once per render — so an appearance change needs an explicit redraw.
    /// The button's own appearance is the one signal that covers both causes:
    /// a system Light/Dark switch and a wallpaper-driven menu bar flip.
    private func observeAppearanceChanges(button: NSStatusBarButton) {
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.rerenderForAppearanceChange()
            }
        }
    }

    /// Re-applies the current rendering against the new menu bar appearance.
    private func rerenderForAppearanceChange() {
        updateMenuBarDisplay(with: appState.usageData, settings: appState.settings)
    }

    private func setupPopover() {
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 380, height: 420)
        pop.behavior = .transient

        let popoverView = PopoverView(appState: appState)
        pop.contentViewController = NSHostingController(rootView: popoverView)
        popover = pop
    }

    private func setupSubscriptions() {
        // Update menu bar based on usage and display mode
        Publishers.CombineLatest(appState.$usageData, appState.$settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data, settings in
                self?.updateMenuBarDisplay(with: data, settings: settings)
            }
            .store(in: &cancellables)
    }

    // MARK: - Display Mode Rendering

    private func updateMenuBarDisplay(with data: UsageData?, settings: AppSettings) {
        guard let button = statusItem?.button else { return }

        // Use the 5-hour window for the single-value menu bar modes.
        let fiveHour = data?.fiveHour
        let fiveHourUsage = fiveHour?.utilization ?? 0
        let fiveHourColor = ColorTheme.color(
            for: WindowForecast.make(
                utilization: fiveHourUsage,
                resetsAt: fiveHour?.resetsAt,
                duration: Constants.Window.fiveHourDuration
            ),
            fallbackUsage: fiveHourUsage
        )

        switch settings.displayMode {
        case .iconOnly:
            updateIconOnlyMode(button: button, usage: fiveHourUsage, color: fiveHourColor)
        case .compact:
            updateCompactMode(button: button, usage: fiveHourUsage, color: fiveHourColor)
        case .detailed:
            let color = MenuBarAppearance.labelColor(for: button.effectiveAppearance)
            updateDetailedMode(button: button, data: data, style: settings.detailedModeStyle, color: color)
        }
    }

    // MARK: - Icon Only Mode
    private func updateIconOnlyMode(button: NSStatusBarButton, usage: Double, color: Color) {
        button.title = ""
        button.image = createProgressIcon(progress: usage / 100.0, color: color)
    }

    // MARK: - Compact Mode (Icon + Percentage)
    private func updateCompactMode(button: NSStatusBarButton, usage: Double, color: Color) {
        button.image = createProgressIcon(progress: usage / 100.0, color: color)
        button.title = String(format: " %.0f%%", usage)
        button.imagePosition = .imageLeading
    }

    // MARK: - Detailed Mode

    /// Renders each window as `[icon] used% trailing`, matching the reference
    /// menu-bar design: the percentage takes the usage colour, while the icon
    /// and trailing label take the system label colour, so they sit at the same
    /// weight as the clock and battery readouts. A thin vertical divider
    /// separates the 5-hour (clock) and 7-day (calendar) windows.
    private func updateDetailedMode(button: NSStatusBarButton, data: UsageData?, style: DetailedModeStyle, color: NSColor) {
        button.image = nil

        guard let data = data else {
            button.attributedTitle = mutedTitle("-- | --", color: color)
            return
        }

        // Rebuilt per render rather than cached: toggling "24-hour time" in
        // System Settings changes the hour cycle without changing the locale
        // identifier, so a long-lived formatter would keep the stale format.
        let resetFormatter = ResetTimeFormatter()
        var segments: [NSAttributedString] = []

        if let fiveHour = data.fiveHour {
            segments.append(windowSegment(
                fiveHour,
                symbol: "clock",
                fixedLabel: "5h",
                style: style,
                units: .hoursMinutes,
                duration: Constants.Window.fiveHourDuration,
                color: color,
                resetFormatter: resetFormatter
            ))
        }

        if let sevenDay = data.sevenDay {
            segments.append(windowSegment(
                sevenDay,
                symbol: "calendar",
                fixedLabel: "7d",
                style: style,
                units: .daysHours,
                duration: Constants.Window.sevenDayDuration,
                color: color,
                resetFormatter: resetFormatter
            ))
        }

        guard !segments.isEmpty else {
            button.attributedTitle = mutedTitle("No data", color: color)
            return
        }

        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { title.append(dividerString(color: color)) }
            title.append(segment)
        }
        button.attributedTitle = title
    }

    // MARK: - Detailed Mode Rendering

    private var percentFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    private var labelFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }

    /// Builds one window's `[icon] used% trailing` run.
    /// The percentage is always the used utilization (coloured by level). The
    /// trailing label is the time-until-reset in `.countdown` style, the reset
    /// clock time in `.resetTime` style — both falling back to the fixed
    /// "5h"/"7d" label when no reset time is known — and the fixed label in
    /// `.fixed` style.
    private func windowSegment(
        _ window: UsageWindow,
        symbol: String,
        fixedLabel: String,
        style: DetailedModeStyle,
        units: MenuBarCountdownFormatter.Units,
        duration: TimeInterval,
        color: NSColor,
        resetFormatter: ResetTimeFormatter
    ) -> NSAttributedString {
        let usage = window.utilization
        let forecast = WindowForecast.make(utilization: usage, resetsAt: window.resetsAt, duration: duration)
        let percentColor = ColorTheme.nsColor(for: forecast, fallbackUsage: usage)

        let trailing: String
        switch style {
        case .fixed:
            trailing = fixedLabel
        case .countdown:
            trailing = countdownLabel(until: window.resetsAt, units: units) ?? fixedLabel
        case .resetTime:
            trailing = resetFormatter.label(for: window.resetsAt) ?? fixedLabel
        }

        let segment = NSMutableAttributedString()
        segment.append(symbolString(symbol, color: color))
        segment.append(NSAttributedString(string: "  ", attributes: [.font: labelFont]))
        segment.append(NSAttributedString(string: "\(Int(usage))%", attributes: [
            .foregroundColor: percentColor,
            .font: percentFont
        ]))
        segment.append(NSAttributedString(string: " ", attributes: [.font: labelFont]))
        segment.append(NSAttributedString(string: trailing, attributes: [
            .foregroundColor: color,
            .font: labelFont
        ]))
        return segment
    }

    /// Thin vertical divider drawn between the two windows.
    private func dividerString(color: NSColor) -> NSAttributedString {
        return NSAttributedString(string: "  |  ", attributes: [
            .foregroundColor: color.withAlphaComponent(0.5),
            .font: labelFont
        ])
    }

    /// Neutral placeholder title used for the no-data / loading states.
    private func mutedTitle(_ string: String, color: NSColor) -> NSAttributedString {
        return NSAttributedString(string: string, attributes: [
            .foregroundColor: color,
            .font: labelFont
        ])
    }

    /// Renders an SF Symbol as an inline, vertically-centred, tinted attachment.
    private func symbolString(_ name: String, color: NSColor) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tinted = tintedImage(symbol, color: color)
            attachment.image = tinted
            // Centre the glyph on the text's cap height.
            let y = (percentFont.capHeight - tinted.size.height) / 2
            attachment.bounds = CGRect(x: 0, y: y, width: tinted.size.width, height: tinted.size.height)
        }
        return NSAttributedString(attachment: attachment)
    }

    /// Returns a non-template copy of `image` filled with `color`.
    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    /// Build a collapsed countdown label from now until `resetsAt`.
    /// Returns nil when the reset time is missing or already past.
    private func countdownLabel(until resetsAt: Date?, units: MenuBarCountdownFormatter.Units) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        return MenuBarCountdownFormatter.label(remaining: remaining, units: units)
    }

    // MARK: - Progress Icon Creation

    /// Creates a circular progress icon for the menu bar
    private func createProgressIcon(progress: Double, color: Color) -> NSImage {
        let size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current?.cgContext
            context?.clear(rect)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 2
            let lineWidth: CGFloat = 2.5

            // Background circle (gray)
            let backgroundPath = NSBezierPath()
            backgroundPath.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 0,
                endAngle: 360
            )
            NSColor.systemGray.withAlphaComponent(0.3).setStroke()
            backgroundPath.lineWidth = lineWidth
            backgroundPath.stroke()

            // Progress arc
            let clampedProgress = min(max(progress, 0), 1)
            if clampedProgress > 0 {
                let startAngle: CGFloat = 90  // Start from top
                let endAngle: CGFloat = 90 - (CGFloat(clampedProgress) * 360)

                let progressPath = NSBezierPath()
                progressPath.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: true
                )
                NSColor(color).setStroke()
                progressPath.lineWidth = lineWidth
                progressPath.lineCapStyle = .round
                progressPath.stroke()
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - Popover Toggle

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let statusItem = statusItem,
              let popover = popover,
              let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            removeEventMonitor()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            setupEventMonitor()

            // Only refresh if data is stale
            if appState.pollingManager.isDataStale(lastUpdateTime: appState.lastUpdateTime) {
                Task {
                    await appState.refresh(reason: "popover_open")
                }
            }
        }
    }

    // MARK: - Public Methods

    func showPopover() {
        guard let statusItem = statusItem,
              let popover = popover,
              let button = statusItem.button,
              !popover.isShown else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func hidePopover() {
        guard let popover = popover, popover.isShown else { return }
        popover.performClose(nil)
        removeEventMonitor()
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown else { return }

            self.hidePopover()
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    deinit {
        appearanceObservation?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Menu Bar Appearance

/// The appearance the menu bar is drawn in.
///
/// macOS tints the menu bar from the desktop wallpaper, so it can draw
/// white-on-dark while the system — and `AppleInterfaceStyle` — are still
/// Light. Only the status bar button reports that appearance.
enum MenuBarAppearance {
    /// The system label color, at the same weight as the clock and battery
    /// readouts, flattened for `appearance`. Flattening matters because a
    /// dynamic catalog color stored in the status item's attributed title keeps
    /// resolving to its old value after a switch.
    static func labelColor(for appearance: NSAppearance) -> NSColor {
        var flattened = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            flattened = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return flattened
    }
}

// MARK: - Reset Time Formatter

/// Renders the exact reset clock time, e.g. "15:30" — or "3:30 PM" on a 12-hour
/// machine. A reset that does not fall on the current day is prefixed with the
/// localized short weekday, e.g. "Thu 15:30".
struct ResetTimeFormatter {
    private let time: DateFormatter
    private let weekday: DateFormatter
    private let calendar: Calendar

    init(locale: Locale = .current, timeZone: TimeZone = .current, calendar: Calendar = .current) {
        var resolvedCalendar = calendar
        resolvedCalendar.locale = locale
        resolvedCalendar.timeZone = timeZone
        self.calendar = resolvedCalendar

        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.calendar = resolvedCalendar
        time.dateStyle = .none
        time.timeStyle = .short
        self.time = time

        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.timeZone = timeZone
        weekday.calendar = resolvedCalendar
        weekday.setLocalizedDateFormatFromTemplate("EEE")
        self.weekday = weekday
    }

    /// Returns nil when the reset time is missing or already past, so callers
    /// can fall back to the fixed "5h"/"7d" label — same as `.countdown`.
    func label(for resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }

        let clock = time.string(from: resetsAt)
        guard !calendar.isDate(resetsAt, inSameDayAs: now) else { return clock }
        return "\(weekday.string(from: resetsAt)) \(clock)"
    }
}
