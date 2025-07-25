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
import Combine

class ProgressViewModel: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Initializing..."
    @Published var isRunning: Bool = true
    @Published var isCancelled: Bool = false
    @Published var leftButtonTitle: String = "Cancel"
    @Published var reportPath: String?
    
    private var cancellationHandler: (() -> Void)?
    private var openReportHandler: ((String) -> Void)?
    
    var leftButtonDisabled: Bool {
        // Button is disabled only if cancelled
        return isCancelled && reportPath == nil
    }
    
    func setCancellationHandler(_ handler: @escaping () -> Void) {
        self.cancellationHandler = handler
    }
    
    func setOpenReportHandler(_ handler: @escaping (String) -> Void) {
        self.openReportHandler = handler
    }
    
    func updateProgress(_ value: Double, message: String) {
        // Already called on main thread from WiFiDiagnosticsCollector
        self.progress = min(max(value, 0.0), 1.0)
        self.statusMessage = message
        
        // Check if this is the "Report generated successfully" message
        if message == "Report generated successfully" && value >= 1.0 {
            print("WARNING: Received 'Report generated successfully' but complete() not called yet")
            // Don't update button states here - wait for complete() to be called
        }
    }
    
    func complete(reportPath: String) {
        // Should be called on main thread
        print("ProgressViewModel.complete called with path: \(reportPath)")
        self.progress = 1.0
        self.statusMessage = "Report saved to: \(reportPath)"
        self.isRunning = false
        self.leftButtonTitle = "Open Report"
        self.reportPath = reportPath
        print("After complete - isRunning: \(self.isRunning), leftButtonTitle: \(self.leftButtonTitle)")
    }
    
    func cancel() {
        // Should be called on main thread
        self.isCancelled = true
        self.isRunning = false
        self.statusMessage = "Cancelled"
        self.cancellationHandler?()
    }
    
    func leftButtonAction() {
        if isRunning {
            cancel()
        } else if let path = reportPath {
            openReportHandler?(path)
        }
    }
}

struct ProgressWindowView: View {
    @ObservedObject var viewModel: ProgressViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("WiFi Diagnostics")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 8) {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 300)
                
                Text(viewModel.statusMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 300)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 12) {
                Button(viewModel.leftButtonTitle) {
                    viewModel.leftButtonAction()
                }
                .disabled(viewModel.leftButtonDisabled)
                
                Button("Close") {
                    dismiss()
                }
                .disabled(viewModel.isRunning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 400, height: 200)
    }
}

class ProgressWindowController {
    private var window: NSWindow?
    private var viewModel: ProgressViewModel
    
    init() {
        self.viewModel = ProgressViewModel()
    }
    
    func show() {
        DispatchQueue.main.async {
            if self.window == nil {
                self.window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                self.window?.title = "Generating Report"
                self.window?.center()
                self.window?.isReleasedWhenClosed = false
            }
            
            let hostingController = NSHostingController(rootView: ProgressWindowView(viewModel: self.viewModel))
            self.window?.contentViewController = hostingController
            self.window?.makeKeyAndOrderFront(nil)
            
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func updateProgress(_ value: Double, message: String) {
        viewModel.updateProgress(value, message: message)
    }
    
    func complete(reportPath: String) {
        print("ProgressWindowController.complete called with path: \(reportPath)")
        viewModel.complete(reportPath: reportPath)
    }
    
    func setCancellationHandler(_ handler: @escaping () -> Void) {
        viewModel.setCancellationHandler(handler)
    }
    
    func setOpenReportHandler(_ handler: @escaping (String) -> Void) {
        viewModel.setOpenReportHandler(handler)
    }
    
    func close() {
        window?.close()
        window = nil
    }
}