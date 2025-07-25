/*
 * Copyright 2024 Ravi Pina <ravi@pina.org>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import SwiftUI
import UserNotifications
import AppKit

@main
struct WiFiDiagnosticsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Check if running from command line
        if CommandLine.arguments.count > 1 {
            if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
                printHelp()
                exit(0)
            } else if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("-c") {
                runCLIMode()
                exit(0)
            }
        }
    }
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
    
    private func runCLIMode() {
        print("WiFi Diagnostics - Command Line Mode")
        print("Generating report...")
        
        let diagnostics = WiFiDiagnosticsCollector()
        let semaphore = DispatchSemaphore(value: 0)
        var reportContent = ""
        
        diagnostics.generateReport { report in
            reportContent = report
            semaphore.signal()
        }
        
        // Wait for report generation
        _ = semaphore.wait(timeout: .now() + .seconds(20))
        
        // Handle command line arguments
        if CommandLine.arguments.contains("--stdout") || CommandLine.arguments.contains("-s") {
            // Output to stdout
            print("\n" + reportContent)
        } else {
            // Save to file
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let fileName = "WiFiDiagnostics_\(timestamp).txt"
            
            let outputPath: String
            if let index = CommandLine.arguments.firstIndex(of: "--output"),
               index + 1 < CommandLine.arguments.count {
                outputPath = CommandLine.arguments[index + 1]
            } else if let index = CommandLine.arguments.firstIndex(of: "-o"),
                      index + 1 < CommandLine.arguments.count {
                outputPath = CommandLine.arguments[index + 1]
            } else {
                // Default to current directory
                outputPath = FileManager.default.currentDirectoryPath + "/" + fileName
            }
            
            do {
                try reportContent.write(toFile: outputPath, atomically: true, encoding: .utf8)
                print("Report saved to: \(outputPath)")
            } catch {
                print("Error saving report: \(error)")
                print("\n" + reportContent)
            }
        }
    }
    
    private func printHelp() {
        print("""
        WiFi Diagnostics - Network diagnostic tool for macOS
        
        Usage: WiFiDiagnostics [options]
        
        Options:
          --cli, -c              Run in command line mode (required for terminal use)
          --stdout, -s           Output report to stdout instead of file
          --output, -o <path>    Specify output file path (default: current directory)
          --help, -h             Show this help message
        
        Examples:
          WiFiDiagnostics --cli                    Generate report and save to current directory
          WiFiDiagnostics -c -s                    Generate report and print to stdout
          WiFiDiagnostics -c -o ~/Desktop/wifi.txt Generate report and save to specific path
        
        Note: Without --cli flag, the app runs as a menu bar application.
        """)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var diagnosticsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var progressWindow: ProgressWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestNotificationPermission()
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("Notification permission granted")
            } else if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            updateMenuBarIcon()
            button.action = #selector(toggleMenu)
            
            // Observe appearance changes
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(appearanceChanged),
                name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil
            )
        }
        
        setupMenu()
    }
    
    @objc private func appearanceChanged() {
        updateMenuBarIcon()
    }
    
    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        
        // Use the app icon from Assets.xcassets
        if let appIcon = NSImage(named: "AppIcon") {
            let menuBarIcon = NSImage(size: NSSize(width: 18, height: 18))
            menuBarIcon.lockFocus()
            appIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            menuBarIcon.unlockFocus()
            menuBarIcon.isTemplate = true // Let macOS handle light/dark mode automatically
            button.image = menuBarIcon
        } else {
            // Fallback to system icon if app icon not found
            button.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "WiFi Diagnostics")
        }
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Generate WiFi Diagnostics", action: #selector(generateDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About WiFi Diagnostics", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc private func toggleMenu() {
        // Menu will show automatically when button is clicked
    }
    
    @objc private func generateDiagnostics() {
        // Create progress window and diagnostics collector
        progressWindow = ProgressWindowController()
        let diagnostics = WiFiDiagnosticsCollector()
        
        // Set up progress tracking BEFORE showing window
        diagnostics.setProgressHandler { [weak self] progress, message in
            DispatchQueue.main.async {
                self?.progressWindow?.updateProgress(progress, message: message)
            }
        }
        
        // Set up cancellation
        progressWindow?.setCancellationHandler { [weak diagnostics] in
            diagnostics?.cancel()
        }
        
        // Set up open report handler
        progressWindow?.setOpenReportHandler { [weak self] path in
            self?.showDiagnosticsWindowForPath(path)
        }
        
        // Show the window
        progressWindow?.show()
        
        // Start diagnostics generation after a brief delay for window to appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Start with notification permission message
            self.progressWindow?.updateProgress(0.05, message: "Notification permission granted")
            
            // Generate report on background queue
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                diagnostics.generateReport { [weak self] report in
                    print("WiFiDiagnosticsApp: Completion handler called with report size: \(report.count)")
                    DispatchQueue.main.async {
                        print("WiFiDiagnosticsApp: On main queue")
                        guard let self = self, let progressWindow = self.progressWindow else { 
                            print("WiFiDiagnosticsApp: self or progressWindow is nil")
                            return 
                        }
                    
                    // Check if cancelled
                    if report.contains("cancelled") {
                        progressWindow.updateProgress(0.0, message: "Cancelled")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            progressWindow.close()
                        }
                        return
                    }
                    
                    // Update progress to show we're saving
                    progressWindow.updateProgress(0.98, message: "Saving report to file...")
                    
                    // Save to file and complete
                    if let reportPath = self.saveReportToFile(report) {
                        print("Report saved, calling progressWindow.complete with path: \(reportPath)")
                        progressWindow.complete(reportPath: reportPath)
                    } else {
                        print("Error saving report")
                        progressWindow.updateProgress(1.0, message: "Error saving report")
                    }
                }
            }
        }
    }
    }
    
    private func saveReportToFile(_ report: String) -> String? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "WiFiDiagnostics_\(timestamp).txt"
        
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let fileURL = downloadsURL.appendingPathComponent(fileName)
        
        do {
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Report saved to: \(fileURL.path)")
            
            // Show notification
            let content = UNMutableNotificationContent()
            content.title = "WiFi Diagnostics"
            content.body = "Report saved to Downloads folder"
            content.sound = UNNotificationSound.default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Failed to show notification: \(error)")
                }
            }
            
            return fileURL.path
        } catch {
            print("Failed to save report: \(error)")
            return nil
        }
    }
    
    private func showDiagnosticsWindowForPath(_ path: String) {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            showDiagnosticsWindow(with: content)
        } catch {
            print("Failed to read report file: \(error)")
        }
    }
    
    private func showDiagnosticsWindow(with content: String) {
        if diagnosticsWindow == nil {
            diagnosticsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            diagnosticsWindow?.title = "WiFi Diagnostics Report"
            diagnosticsWindow?.center()
        }
        
        // Check if we need to show a permission button
        let needsLocationPermission = content.contains("⚠️ Location Services Required") || 
                                     content.contains("⚠️ Network scan requires Location Services")
        
        if needsLocationPermission {
            // Create a view with text and button
            let containerView = NSView(frame: diagnosticsWindow!.contentView!.bounds)
            containerView.autoresizingMask = [.width, .height]
            
            // Add button at the top
            let button = NSButton(title: "Open Location Services Settings", 
                                target: self, 
                                action: #selector(openLocationSettings))
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(button)
            
            // Create the text view
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = content
            textView.backgroundColor = NSColor.textBackgroundColor
            textView.textColor = NSColor.labelColor
            
            // Configure text container
            textView.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.minSize = CGSize(width: 0, height: 0)
            textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            
            // Create scroll view
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 40, width: 800, height: 560))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder
            scrollView.documentView = textView
            scrollView.autoresizingMask = [.width, .height]
            containerView.addSubview(scrollView)
            
            // Add constraints for button
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
                button.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10)
            ])
            
            diagnosticsWindow?.contentView = containerView
        } else {
            // No permission issues, show regular text view
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = content
            textView.backgroundColor = NSColor.textBackgroundColor
            textView.textColor = NSColor.labelColor
            
            // Configure text container
            textView.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.minSize = CGSize(width: 0, height: 0)
            textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            
            // Create scroll view
            let scrollView = NSScrollView(frame: diagnosticsWindow!.contentView!.bounds)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder
            scrollView.documentView = textView
            scrollView.autoresizingMask = [.width, .height]
            
            diagnosticsWindow?.contentView = scrollView
        }
        
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openLocationSettings() {
        LocationPermissionManager.openLocationServicesSettings()
    }
    
    @objc private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            aboutWindow?.title = "About WiFi Diagnostics"
            aboutWindow?.center()
            aboutWindow?.isReleasedWhenClosed = false
        }
        
        let hostingController = NSHostingController(rootView: AboutView())
        aboutWindow?.contentViewController = hostingController
        aboutWindow?.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            // App Icon
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }
            
            // App Name
            Text("WiFi Diagnostics")
                .font(.title2)
                .fontWeight(.semibold)
            
            // Version
            Text("Version 1.0")
                .font(.body)
                .foregroundColor(.secondary)
            
            // Description
            Text("Generate Wi-Fi diagnostics to aid in troubleshooting.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
                .frame(height: 8)
            
            // Copyright
            VStack(spacing: 4) {
                Text("Copyright (C) 2025 Ravi Pina")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("All rights reserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 30)
        .frame(width: 400, height: 300)
    }
}
