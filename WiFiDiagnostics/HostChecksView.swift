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

struct HostChecksView: View {
    @Environment(\.dismiss) var dismiss
    @State private var hostsText: String = ""

    static let defaultHosts = "apple.com\nmail.google.com\n1.1.1.1\n8.8.8.8"
    private static let userDefaultsKey = "customTestHosts"

    var body: some View {
        VStack(spacing: 16) {
            Text("Enter hostnames or IP addresses, one per line. Each will be checked for DNS resolution and pinged 5 times. The default gateway is always checked automatically.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $hostsText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color(NSColor.separatorColor), width: 1)

            HStack {
                Button("Restore Defaults") {
                    hostsText = Self.defaultHosts
                }

                Spacer()

                Button("Cancel") {
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    UserDefaults.standard.set(hostsText, forKey: Self.userDefaultsKey)
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 450, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: Self.userDefaultsKey) {
                hostsText = saved
            } else {
                hostsText = Self.defaultHosts
            }
        }
    }

    private func closeWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Host Checks" }) {
            window.close()
        }
    }
}

class HostChecksWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Host Checks"
        window.center()

        let hostingController = NSHostingController(rootView: HostChecksView())
        window.contentViewController = hostingController

        self.init(window: window)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
