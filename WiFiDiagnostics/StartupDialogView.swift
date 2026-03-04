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
import CoreLocation
import ServiceManagement

struct StartupDialogView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isProcessing = false
    @State private var hideAtStartup = false
    @State private var locationGranted: Bool? = nil
    @State private var launchAtLoginEnabled = false
    // Must be retained as a property so CLLocationManager stays alive for the authorization prompt
    @StateObject private var locationPermissionManager = LocationPermissionManager()
    
    var body: some View {
        VStack(spacing: 24) {
            // App Icon
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }
            
            Text("Welcome to WiFi Diagnostics")
                .font(.title)
                .fontWeight(.semibold)
            
            Text("Please configure the following settings to get started:")
                .font(.body)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                // Grant Location Permissions
                HStack(alignment: .center, spacing: 16) {
                    Button(action: grantLocationPermissions) {
                        Text("Grant Location Permissions")
                            .frame(width: 180)
                    }
                    .disabled(isProcessing)

                    statusIcon(for: locationGranted)

                    Text("Required for WiFi scanning and detailed network information")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Launch at Startup
                HStack(alignment: .center, spacing: 16) {
                    Button(action: setupLaunchAtStartup) {
                        Text("Launch at Startup")
                            .frame(width: 180)
                    }
                    .disabled(isProcessing)

                    statusIcon(for: launchAtLoginEnabled)

                    Text("Automatically start WiFi Diagnostics when you log in")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Continue button
                HStack(alignment: .center, spacing: 16) {
                    Button(action: continueToMenuBar) {
                        Text("Continue")
                            .frame(width: 180)
                    }
                    .disabled(isProcessing)

                    Text("Close dialog and run in the menubar")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            Spacer()
            
            // Quit button
            Button(action: quitApplication) {
                Text("Quit")
                    .frame(width: 100)
            }
            .disabled(isProcessing)
            
            Toggle("Hide this at next startup", isOn: $hideAtStartup)
                .onChange(of: hideAtStartup) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "hideStartupDialog")
                }
            
            Text("You can change these settings later from the menu bar")
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
        .padding(30)
        .frame(width: 600, height: 550)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            let status = CLLocationManager().authorizationStatus
            switch status {
            case .authorized, .authorizedAlways:
                locationGranted = true
            case .denied, .restricted:
                locationGranted = false
            default:
                locationGranted = nil
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
    
    @ViewBuilder
    private func statusIcon(for state: Bool?) -> some View {
        switch state {
        case .some(true):
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .frame(width: 20)
        case .some(false):
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .frame(width: 20)
        case .none:
            Image(systemName: "questionmark.circle")
                .foregroundColor(.orange)
                .frame(width: 20)
        }
    }

    private func grantLocationPermissions() {
        isProcessing = true

        locationPermissionManager.requestLocationPermission { granted in
            DispatchQueue.main.async {
                locationGranted = granted
                if !granted {
                    // Permission denied or restricted — open System Settings
                    LocationPermissionManager.openLocationServicesSettings()
                }
                isProcessing = false
            }
        }
    }

    private func setupLaunchAtStartup() {
        isProcessing = true

        // Use Service Management API for launch at login
        do {
            if SMAppService.mainApp.status == .enabled {
                // Already enabled
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            print("Failed to setup launch at startup: \(error)")
            launchAtLoginEnabled = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isProcessing = false
        }
    }
    
    private func continueToMenuBar() {
        // Close the dialog window
        if let window = NSApplication.shared.windows.first(where: { $0.title == "WiFi Diagnostics Setup" }) {
            window.close()
        }
    }
    
    private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}

class StartupDialogWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WiFi Diagnostics Setup"
        window.center()
        
        let hostingController = NSHostingController(rootView: StartupDialogView())
        window.contentViewController = hostingController
        
        self.init(window: window)
    }
    
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}