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

import Foundation
import CoreWLAN
import SystemConfiguration
import Darwin
import Network
import CoreLocation
import AppKit

// Constants for sysctl
private let CTL_NET = 4
private let PF_ROUTE = 17
private let NET_RT_DUMP = 1

// Routing message types
private let RTM_GET = 0x4
private let RTM_ADD = 0x1
private let RTM_DELETE = 0x2
private let RTM_CHANGE = 0x3

// Route flags
private let RTF_UP = 0x1
private let RTF_GATEWAY = 0x2
private let RTF_HOST = 0x4
private let RTF_STATIC = 0x800
private let RTF_LOCAL = 0x200000

// Address family
private let AF_LINK = 18

// Routing message structure
struct rt_msghdr {
    var rtm_msglen: UInt16
    var rtm_version: UInt8
    var rtm_type: UInt8
    var rtm_index: UInt16
    var rtm_flags: Int32
    var rtm_addrs: Int32
    var rtm_pid: pid_t
    var rtm_seq: Int32
    var rtm_errno: Int32
    var rtm_use: Int32
    var rtm_inits: UInt32
    var rtm_rmx: rt_metrics
}

struct rt_metrics {
    var rmx_locks: UInt32
    var rmx_mtu: UInt32
    var rmx_hopcount: UInt32
    var rmx_expire: Int32
    var rmx_recvpipe: UInt32
    var rmx_sendpipe: UInt32
    var rmx_ssthresh: UInt32
    var rmx_rtt: UInt32
    var rmx_rttvar: UInt32
    var rmx_pksent: UInt32
    var rmx_filler: (UInt32, UInt32, UInt32, UInt32)
}

// Location Manager for handling location permissions
class LocationPermissionManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    private let locationManager = CLLocationManager()
    private var completion: ((Bool) -> Void)?
    
    override init() {
        super.init()
        locationManager.delegate = self
    }
    
    func requestLocationPermission(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        
        // Check current authorization status
        let status = locationManager.authorizationStatus
        
        switch status {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            // Request permission
            locationManager.requestWhenInUseAuthorization()
            // Safety timeout: if macOS doesn't show a prompt or the delegate
            // callback never fires, fall back after a few seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, let completion = self.completion else { return }
                self.completion = nil
                completion(false)
            }
        @unknown default:
            completion(false)
        }
    }
    
    // CLLocationManagerDelegate methods
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        switch status {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            completion?(true)
        case .denied, .restricted:
            completion?(false)
        case .notDetermined:
            // Still waiting for user decision
            break
        @unknown default:
            completion?(false)
        }
        
        // Only clear completion if we got a definitive answer
        if status != .notDetermined {
            completion = nil
        }
    }
    
    // Helper method to open System Settings
    static func openLocationServicesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

class PhaseProgressTracker {
    enum DiagnosticPhase: CaseIterable {
        case wifiInfo
        case networkInterfaces
        case activeConnections
        case dnsTests
        case pingTests
        case dhcpLease
        case captivePortal
        case mdns
        case security
        case finalizing

        var weight: Double {
            switch self {
            case .dnsTests: return 0.28
            case .pingTests: return 0.22
            case .wifiInfo: return 0.12
            case .networkInterfaces: return 0.08
            case .activeConnections: return 0.08
            case .dhcpLease: return 0.04
            case .captivePortal: return 0.04
            case .mdns: return 0.04
            case .security: return 0.06
            case .finalizing: return 0.04
            }
        }

        var displayName: String {
            switch self {
            case .wifiInfo: return "WiFi Info"
            case .networkInterfaces: return "Network Interfaces"
            case .activeConnections: return "Active Connections"
            case .dnsTests: return "DNS Tests"
            case .pingTests: return "Ping Tests"
            case .dhcpLease: return "DHCP Lease"
            case .captivePortal: return "Captive Portal"
            case .mdns: return "mDNS Discovery"
            case .security: return "Security"
            case .finalizing: return "Finalizing"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.wifidiagnostics.phasetracker")
    private var phaseProgress: [DiagnosticPhase: Double] = [:]
    private var activeMessages: [DiagnosticPhase: String] = [:]
    private var isComplete = false
    var handler: ((Double, String) -> Void)?

    func update(phase: DiagnosticPhase, progress: Double, detail: String) {
        let result: (Double, String)? = queue.sync {
            guard !isComplete else { return nil }
            phaseProgress[phase] = min(max(progress, 0.0), 1.0)
            if progress < 1.0 {
                activeMessages[phase] = "\(phase.displayName) \u{2014} \(detail)"
            } else {
                activeMessages.removeValue(forKey: phase)
            }
            // Show the highest-weight phase that is still active
            let message = activeMessages
                .max(by: { $0.key.weight < $1.key.weight })?
                .value ?? "\(phase.displayName) \u{2014} \(detail)"
            let overall = computeOverall_locked()
            return (overall, message)
        }
        if let (overall, message) = result {
            handler?(overall, message)
        }
    }

    func complete() {
        queue.sync {
            isComplete = true
        }
        handler?(1.0, "Report complete")
    }

    /// Must be called while already holding `queue`.
    private func computeOverall_locked() -> Double {
        var total = 0.0
        for phase in DiagnosticPhase.allCases {
            total += (phaseProgress[phase] ?? 0.0) * phase.weight
        }
        return min(total, 1.0)
    }
}

class WiFiDiagnosticsCollector {
    private var logEntries: [String] = []
    private let logQueue = DispatchQueue(label: "com.wifidiagnostics.log")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()

    private var isCancelled = false
    private var progressHandler: ((Double, String) -> Void)?
    private let progressQueue = DispatchQueue(label: "com.wifidiagnostics.progress")
    private var currentProgress: Double = 0.0
    private let locationManager = LocationPermissionManager()
    private var phaseTracker: PhaseProgressTracker?
    private let pingCount = 5

    private lazy var dynamicStore: SCDynamicStore? = {
        SCDynamicStoreCreate(nil, "WiFiDiagnostics" as CFString, nil, nil)
    }()

    private lazy var cachedGateway: String? = {
        guard let store = dynamicStore else { return nil }
        let key = "State:/Network/Global/IPv4" as CFString
        if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
           let router = dict["Router"] as? String {
            return router
        }
        return nil
    }()

    private lazy var cachedDNSServers: [String] = {
        guard let store = dynamicStore else { return [] }
        let key = "State:/Network/Global/DNS" as CFString
        if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
           let servers = dict["ServerAddresses"] as? [String] {
            return servers
        }
        return []
    }()

    private lazy var cachedDNSSearchDomains: [String] = {
        guard let store = dynamicStore else { return [] }
        let key = "State:/Network/Global/DNS" as CFString
        if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
           let domains = dict["SearchDomains"] as? [String] {
            return domains
        }
        return []
    }()

    private func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"
        logQueue.sync {
            logEntries.append(logEntry)
        }
        print(logEntry)
    }
    
    func setProgressHandler(_ handler: @escaping (Double, String) -> Void) {
        self.progressHandler = handler
        let tracker = PhaseProgressTracker()
        tracker.handler = { [weak self] progress, message in
            self?.updateProgress(progress, message)
        }
        self.phaseTracker = tracker
    }

    private func getTestHosts() -> [String] {
        if let saved = UserDefaults.standard.string(forKey: "customTestHosts") {
            let hosts = saved.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !hosts.isEmpty { return hosts }
        }
        return ["apple.com", "mail.google.com", "1.1.1.1", "8.8.8.8"]
    }

    private func isIPAddress(_ host: String) -> Bool {
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        return host.withCString { cStr in
            inet_pton(AF_INET, cStr, &sin.sin_addr) == 1 ||
            inet_pton(AF_INET6, cStr, &sin6.sin6_addr) == 1
        }
    }
    
    func cancel() {
        isCancelled = true
    }
    
    private func updateProgress(_ progress: Double, _ message: String) {
        guard !isCancelled else { return }
        let shouldUpdate: Bool = progressQueue.sync {
            guard progress >= currentProgress else { return false }
            currentProgress = progress
            return true
        }
        guard shouldUpdate else { return }
        log("Progress: \(Int(progress * 100))% - \(message)")
        progressHandler?(progress, message)
    }
    
    func generateReport(completion: @escaping (String) -> Void) {
        logQueue.sync { logEntries.removeAll() }
        isCancelled = false
        progressQueue.sync { currentProgress = 0.0 }
        log("Starting WiFi diagnostics collection...")
        updateProgress(0.1, "Initializing diagnostics...")

        var report = "=== WiFi Diagnostics Report ===\n"
        report += "Generated: \(Date())\n\n"

        // System info header (fast, no I/O contention)
        report += generateSystemInfoHeader()

        let group = DispatchGroup()
        var wifiSection = ""
        var networkSection = ""
        var connectionsSection = ""
        var dnsSection = ""
        var pingSection = ""
        var dhcpSection = ""
        var captivePortalSection = ""
        var mdnsSection = ""

        let testHosts = getTestHosts()
        let hostCount = testHosts.count

        // WiFi Information (with timeout)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .wifiInfo, progress: 0.0, detail: "Starting system profiler...")
            wifiSection = self.generateWiFiInfo()
            self.phaseTracker?.update(phase: .wifiInfo, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // Network Interfaces
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .networkInterfaces, progress: 0.0, detail: "Scanning...")
            networkSection = "\n" + self.generateNetworkInterfaceInfo()
            self.phaseTracker?.update(phase: .networkInterfaces, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // Active Connections
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .activeConnections, progress: 0.0, detail: "Analyzing...")
            connectionsSection = "\n" + self.generateActiveConnectionsInfo()
            self.phaseTracker?.update(phase: .activeConnections, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // DNS Information
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .dnsTests, progress: 0.0, detail: "Starting DNS tests...")
            dnsSection = "\n" + self.generateDNSInfo(testHosts: testHosts)
            self.phaseTracker?.update(phase: .dnsTests, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // Gateway Ping / Latency Test
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .pingTests, progress: 0.0, detail: "Starting ping tests...")
            var section = "\n--- Gateway Ping / Latency Test ---\n"
            var pingTargets: [String] = []
            if let gateway = self.getDefaultGateway() {
                section += "\nPing to gateway (\(gateway)):\n"
                section += self.performPingTest(host: gateway, count: self.pingCount)
                pingTargets.append(gateway)
            } else {
                section += "No default gateway found\n"
            }
            for (index, host) in testHosts.enumerated() {
                guard !self.isCancelled else { break }
                self.phaseTracker?.update(phase: .pingTests, progress: Double(index) / Double(testHosts.count + 1), detail: "Pinging \(host) (\(index + 1)/\(testHosts.count))...")
                section += "\nPing to \(host):\n"
                section += self.performPingTest(host: host, count: self.pingCount)
            }
            pingSection = section
            self.phaseTracker?.update(phase: .pingTests, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // DHCP Lease Information
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .dhcpLease, progress: 0.0, detail: "Collecting...")
            dhcpSection = "\n" + self.getDHCPLeaseInfo()
            self.phaseTracker?.update(phase: .dhcpLease, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // Captive Portal Detection
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .captivePortal, progress: 0.0, detail: "Checking...")
            captivePortalSection = "\n" + self.performCaptivePortalTest()
            self.phaseTracker?.update(phase: .captivePortal, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // mDNS/Bonjour Service Discovery
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled else {
                group.leave()
                return
            }
            self.phaseTracker?.update(phase: .mdns, progress: 0.0, detail: "Discovering services...")
            mdnsSection = "\n" + self.performMDNSCheck()
            self.phaseTracker?.update(phase: .mdns, progress: 1.0, detail: "Complete")
            group.leave()
        }

        // Wait with timeout (scaled to number of hosts)
        let timeoutSeconds = max(30, hostCount * 15 + 15)
        let timeout = DispatchTime.now() + .seconds(timeoutSeconds)
        let result = group.wait(timeout: timeout)

        if self.isCancelled {
            log("Report generation cancelled")
            DispatchQueue.main.async {
                completion("Report generation was cancelled.")
            }
            return
        }

        if result == .timedOut {
            log("WARNING: Some operations timed out after \(timeoutSeconds) seconds")
            report += "\n⚠️ Warning: Some operations timed out\n\n"
        }

        // Combine sections (safe - all concurrent work is done after group.wait)
        report += [wifiSection, networkSection, connectionsSection, dnsSection, pingSection, dhcpSection, captivePortalSection, mdnsSection].joined()

        // Add security information (non-sandboxed)
        if !self.isCancelled {
            phaseTracker?.update(phase: .security, progress: 0.0, detail: "Checking firewall...")
            report += "\n" + self.generateSecurityInfo()
            phaseTracker?.update(phase: .security, progress: 1.0, detail: "Complete")
        }

        log("Diagnostics collection completed")
        phaseTracker?.update(phase: .finalizing, progress: 0.5, detail: "Writing report...")
        log("Report size: \(report.count) characters")
        phaseTracker?.update(phase: .finalizing, progress: 1.0, detail: "Complete")
        phaseTracker?.complete()

        // Add debug log as the very last step so it captures all entries
        report += "\n\n--- Debug Log ---\n"
        report += logQueue.sync { logEntries.joined(separator: "\n") }

        // Call completion directly - we're already on a background queue
        completion(report)
    }
    
    private func generateWiFiInfo() -> String {
        log("Collecting WiFi information...")
        var info = "--- WiFi Information ---\n"
        
        // Check location permission status
        let locationStatus = CLLocationManager().authorizationStatus
        log("Location Services authorization status: \(locationStatus.rawValue)")
        
        if locationStatus == .denied || locationStatus == .restricted {
            info += """
            ⚠️ Location Services Required
            
            WiFi Diagnostics needs Location Services permission to:
            • Retrieve the BSSID (access point MAC address)
            • Scan for nearby WiFi networks
            • Provide complete diagnostic information
            
            To enable Location Services:
            1. Open System Settings > Privacy & Security > Location Services
            2. Find "WiFi Diagnostics" in the list
            3. Enable Location Services for this app
            
            
            """
            log("Location Services denied or restricted - BSSID and network scanning will not be available")
        } else if locationStatus == .notDetermined {
            info += "⚠️ Requesting Location Services permission... Please check the permission prompt.\n\n"
            log("Location Services not determined - requesting permission")
            
            // Request permission synchronously
            let semaphore = DispatchSemaphore(value: 0)
            var permissionGranted = false
            var permissionResponded = false
            
            DispatchQueue.main.async {
                self.locationManager.requestLocationPermission { granted in
                    permissionGranted = granted
                    permissionResponded = true
                    semaphore.signal()
                }
            }
            
            // Wait up to 30 seconds for permission (increased from 5)
            let waitResult = semaphore.wait(timeout: .now() + .seconds(30))
            
            if waitResult == .timedOut {
                log("Location permission request timed out after 30 seconds")
                info += "⚠️ Location permission request timed out. Please restart the diagnostics after granting permission.\n\n"
            } else if permissionResponded {
                log("Location permission result: \(permissionGranted)")
                if !permissionGranted {
                    info += """
                    ⚠️ Location Services permission was denied.
                    
                    To enable it later:
                    1. Open System Settings > Privacy & Security > Location Services
                    2. Find "WiFi Diagnostics" and enable it
                    3. Run diagnostics again
                    
                    
                    """
                }
            }
        }
        
        // Simple approach - exactly like the working example
        guard let interface = CWWiFiClient.shared().interface() else {
            log("No WiFi interface found")
            return info + "No WiFi interface found\n"
        }
        
        log("Found WiFi interface: \(interface.interfaceName ?? "Unknown")")
        
        // Additional debug info
        log("Interface power: \(interface.powerOn())")
        log("Interface service active: \(interface.serviceActive())")
        log("Interface security: \(self.securityString(interface.security()))")
        log("Interface mode: \(self.interfaceModeString(interface.interfaceMode()))")
        
        
        info += "Interface: \(interface.interfaceName ?? "Unknown")\n"
        info += "Power: \(interface.powerOn() ? "On" : "Off")\n"

        // Get SSID
        let ssid = interface.ssid()
        if let ssid = ssid {
            info += "SSID (ESSID): \(ssid)\n"
            log("Connected to SSID: \(ssid)")
        } else {
            info += "SSID: Not connected (CoreWLAN)\n"
            log("CoreWLAN reports WiFi interface not connected to any network")
            log("Security type: \(self.securityString(interface.security()))")
        }
        
        // Always try to get BSSID regardless of SSID status
        // Sometimes CoreWLAN reports no SSID but we are actually connected
        log("Attempting to get BSSID regardless of SSID status...")
        
        // Try to get BSSID - first try CoreWLAN (most direct method)
        let cwBssid = interface.bssid()
        log("CoreWLAN BSSID result: \(cwBssid ?? "nil")")
        
        if let bssid = cwBssid {
            info += "BSSID: \(bssid)\n"
            log("BSSID from CoreWLAN: \(bssid)")
        } else {
            // Fallback to alternative methods
            log("CoreWLAN returned nil for BSSID, trying alternative methods...")
            if let bssid = getBSSIDUsingAlternativeMethods() {
                info += "BSSID: \(bssid)\n"
                log("BSSID from alternative method: \(bssid)")
            } else {
                info += "BSSID: Not available\n"
                log("BSSID is nil from all methods")
                log("Debug info - Interface state: power=\(interface.powerOn()), active=\(interface.serviceActive())")
            }
        }
        
        // Additional connection info
        info += "Interface Mode: \(self.interfaceModeString(interface.interfaceMode()))\n"
        
        // Show signal metrics - try even if SSID is nil
        // Check if we have valid signal data
        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        
        if rssi != 0 || noise != 0 {
            info += "RSSI: \(rssi) dBm (\(rssiQualityLabel(rssi)))\n"
            info += "Noise: \(noise) dBm\n"

            let snr = rssi - noise
            info += "SNR: \(snr) dB (\(snrQualityLabel(snr)))\n"
            
            if let channel = interface.wlanChannel() {
                info += "Channel: \(channel.channelNumber)\n"
                info += "Channel Band: \(channel.channelBand == .band2GHz ? "2.4 GHz" : channel.channelBand == .band5GHz ? "5 GHz" : "6 GHz")\n"
                info += "Channel Width: \(self.channelWidthString(channel.channelWidth))\n"
            }
            
            info += "PHY Mode: \(self.phyModeString(interface.activePHYMode()))\n"
            info += "Transmit Rate: \(interface.transmitRate()) Mbps\n"
            
            // Try to infer MCS from transmit rate and channel width
            if interface.activePHYMode() == .mode11n || interface.activePHYMode() == .mode11ac {
                info += "MCS Index: \(self.getMCSFromRate(rate: interface.transmitRate(), width: interface.wlanChannel()?.channelWidth ?? .width20MHz, mode: interface.activePHYMode()))\n"
            }
            
            let security = interface.security()
            info += "Security: \(self.securityString(security))\n"
            
            // Hardware address
            if let hardwareAddress = interface.hardwareAddress() {
                info += "MAC Address: \(hardwareAddress)\n"
            }
        } else {
            info += "Signal metrics not available\n"
            log("RSSI: \(rssi), Noise: \(noise) - both are 0, likely not connected")
        }
        
        // Scan for nearby networks with timeout
        info += "\n--- Nearby Networks ---\n"
        log("Scanning for nearby networks...")
        
        // Check if Location Services are enabled before scanning
        let scanLocationStatus = CLLocationManager().authorizationStatus
        if scanLocationStatus == .denied || scanLocationStatus == .restricted {
            log("Location Services not authorized for network scanning")
            info += """
              ⚠️ Network scan requires Location Services to be enabled
              
              To see nearby networks:
              1. Open System Settings > Privacy & Security > Location Services
              2. Enable Location Services for WiFi Diagnostics
              3. Run diagnostics again
            
            """
        } else {
            let scanSemaphore = DispatchSemaphore(value: 0)
            var scanResult: Set<CWNetwork>?
            var scanError: Error?
            
            // Note: scanForNetworks must be called on the main thread in some cases
            let scanStartTime = Date()
            
            DispatchQueue.main.async { [weak self] in
                do {
                    self?.log("Starting network scan on main thread...")
                    scanResult = try interface.scanForNetworks(withSSID: nil)
                    self?.log("Network scan completed")
                } catch {
                    scanError = error
                    self?.log("Network scan error: \(error)")
                }
                scanSemaphore.signal()
            }
            
            let scanTimeout = DispatchTime.now() + .seconds(10)  // Increased timeout
            if scanSemaphore.wait(timeout: scanTimeout) == .timedOut {
                let elapsed = Date().timeIntervalSince(scanStartTime)
                log("Network scan timed out after \(String(format: "%.1f", elapsed)) seconds")
                info += "  Scan timed out (10 seconds)\n"
                info += "  Note: Network scanning may take longer in areas with many networks\n"
            } else if let error = scanError {
                log("Network scan failed: \(error.localizedDescription)")
                info += "  Unable to scan: \(error.localizedDescription)\n"
                
                // Check for specific error codes
                let nsError = error as NSError
                if nsError.code == 82 {
                    info += "  This may be due to Location Services permissions\n"
                } else if nsError.code == -3900 {
                    info += "  WiFi interface may be busy or not ready\n"
                }
            } else if let networks = scanResult {
                let scanDuration = Date().timeIntervalSince(scanStartTime)
                log("Found \(networks.count) networks in \(String(format: "%.1f", scanDuration)) seconds")
                
                if networks.isEmpty {
                    info += "  No networks found\n"
                } else {
                    // Sort networks by SSID (network name), case-insensitive, then by RSSI (best to worst)
                    let sortedNetworks = networks.sorted { network1, network2 in
                        let ssid1 = (network1.ssid ?? "").lowercased()
                        let ssid2 = (network2.ssid ?? "").lowercased()
                        
                        if ssid1 == ssid2 {
                            // Same SSID, sort by RSSI (higher is better, so reverse comparison)
                            return network1.rssiValue > network2.rssiValue
                        } else {
                            // Different SSIDs, sort alphabetically
                            return ssid1 < ssid2
                        }
                    }
                    
                    // Add column headers
                    let ssidHeader = "SSID".padding(toLength: 30, withPad: " ", startingAt: 0)
                    let bssidHeader = "BSSID".padding(toLength: 19, withPad: " ", startingAt: 0)
                    let rssiHeader = "RSSI".padding(toLength: 10, withPad: " ", startingAt: 0)
                    let channelHeader = "Channel".padding(toLength: 8, withPad: " ", startingAt: 0)
                    info += "  \(ssidHeader) \(bssidHeader) \(rssiHeader) \(channelHeader) Security\n"
                    
                    let separator = String(repeating: "-", count: 30) + " " +
                                   String(repeating: "-", count: 19) + " " +
                                   String(repeating: "-", count: 10) + " " +
                                   String(repeating: "-", count: 8) + " " +
                                   String(repeating: "-", count: 8)
                    info += "  \(separator)\n"
                    
                    for network in sortedNetworks {  // Show all networks
                        let ssid = network.ssid ?? "Hidden"
                        let bssid = network.bssid ?? "Unknown"
                        let security = network.ibss ? "IBSS" : "Secured"  // Note: detailed security info not available in scan results
                        let rssiStr = "\(network.rssiValue) dBm"
                        let channelStr = "\(network.wlanChannel?.channelNumber ?? 0)"
                        
                        // Truncate SSID if too long
                        let truncatedSSID = ssid.count > 30 ? String(ssid.prefix(27)) + "..." : ssid
                        
                        // Pad each field to the correct width
                        let paddedSSID = truncatedSSID.padding(toLength: 30, withPad: " ", startingAt: 0)
                        let paddedBSSID = bssid.padding(toLength: 19, withPad: " ", startingAt: 0)
                        let paddedRSSI = rssiStr.padding(toLength: 10, withPad: " ", startingAt: 0)
                        let paddedChannel = channelStr.padding(toLength: 8, withPad: " ", startingAt: 0)
                        
                        info += "  \(paddedSSID) \(paddedBSSID) \(paddedRSSI) \(paddedChannel) \(security)\n"
                    }
                    
                    info += "\n  Total networks found: \(networks.count)\n"

                    // Channel Utilization Analysis
                    info += "\n--- Channel Utilization Analysis ---\n"
                    var channelCounts: [Int: Int] = [:]
                    for network in networks {
                        if let ch = network.wlanChannel?.channelNumber {
                            channelCounts[ch, default: 0] += 1
                        }
                    }
                    // Get current channel
                    let currentChannel = interface.wlanChannel()?.channelNumber
                    // Sort by count descending
                    let sorted = channelCounts.sorted { $0.value > $1.value }
                    for (ch, count) in sorted {
                        let marker = (currentChannel != nil && ch == currentChannel) ? " <-- your channel" : ""
                        info += "  Channel \(ch): \(count) network\(count == 1 ? "" : "s")\(marker)\n"
                    }
                    // Recommendation
                    if let curCh = currentChannel, let curCount = channelCounts[curCh], curCount > 1 {
                        // Find least congested channel in same band
                        let curBand = interface.wlanChannel()?.channelBand
                        let sameBandChannels = channelCounts.filter { ch, _ in
                            if curBand == .band2GHz { return ch <= 14 }
                            if curBand == .band5GHz { return ch > 14 && ch <= 177 }
                            return ch > 177
                        }
                        if let best = sameBandChannels.min(by: { $0.value < $1.value }), best.value < curCount {
                            info += "  Recommendation: Channel \(curCh) has \(curCount) competing networks. Channel \(best.key) has only \(best.value).\n"
                        }
                    }
                }
            } else {
                log("Network scan completed but no results or error")
                info += "  No scan results available\n"
            }
        }
        
        // Add system profiler info if available
        info += "\n--- System Profiler WiFi Details ---\n"
        self.updateProgress(0.25, "Gathering system profiler data...")
        if let profilerOutput = self.getDetailedWiFiInfo() {
            // Parse and extract all relevant information from system profiler
            let parsedInfo = self.parseSystemProfilerOutput(profilerOutput)
            info += parsedInfo
        } else {
            info += "Unable to retrieve system profiler data\n"
        }
        
        log("WiFi information collection completed")
        return info
    }
    
    private func generateNetworkInterfaceInfo() -> String {
        log("Collecting network interface information...")
        var info = "--- Network Interfaces ---\n"
        
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        log("Found \(interfaces.count) network interfaces")
        
        for interface in interfaces {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
               let localizedName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                info += "\n\(bsdName) (\(localizedName)):\n"
                log("Processing interface: \(bsdName)")
                
                // Get interface details using ifaddrs
                var ifaddrs: UnsafeMutablePointer<ifaddrs>?
                if getifaddrs(&ifaddrs) == 0 {
                    defer { freeifaddrs(ifaddrs) }
                    
                    var current = ifaddrs
                    while current != nil {
                        let interface = current!.pointee
                        let name = String(cString: interface.ifa_name)
                        
                        if name == bsdName {
                            // Get IP addresses
                            if let address = interface.ifa_addr {
                                let family = address.pointee.sa_family
                                if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                                    getnameinfo(address, socklen_t(address.pointee.sa_len),
                                              &hostname, socklen_t(hostname.count),
                                              nil, 0, NI_NUMERICHOST)
                                    let addressStr = String(cString: hostname)
                                    info += "  \(family == UInt8(AF_INET) ? "IPv4" : "IPv6"): \(addressStr)\n"
                                }
                            }
                            
                            // Get interface flags
                            let flags = interface.ifa_flags
                            var flagStrings: [String] = []
                            if flags & UInt32(IFF_UP) != 0 { flagStrings.append("UP") }
                            if flags & UInt32(IFF_BROADCAST) != 0 { flagStrings.append("BROADCAST") }
                            if flags & UInt32(IFF_LOOPBACK) != 0 { flagStrings.append("LOOPBACK") }
                            if flags & UInt32(IFF_RUNNING) != 0 { flagStrings.append("RUNNING") }
                            if flags & UInt32(IFF_MULTICAST) != 0 { flagStrings.append("MULTICAST") }
                            
                            if !flagStrings.isEmpty {
                                info += "  Flags: \(flagStrings.joined(separator: ", "))\n"
                            }
                        }
                        current = current!.pointee.ifa_next
                    }
                }
            }
        }
        
        log("Network interface information collection completed")
        return info
    }
    
    private func generateActiveConnectionsInfo() -> String {
        log("Collecting active network connections and routing information...")
        var info = "--- Active Network Connections ---\n"
        
        // Without sandbox, we can use netstat directly for better results
        info += self.getNetstatOutput()
        
        // Add routing table information
        info += "\n\n--- Routing Table ---\n"
        info += self.getRoutingTableInfo()
        
        // Add ARP table information (new capability without sandbox)
        info += "\n\n--- ARP Table ---\n"
        info += self.getARPTableInfo()
        
        // Add network interface statistics (new capability without sandbox)
        info += "\n\n--- Network Interface Statistics ---\n"
        info += self.getNetworkStatistics()
        
        log("Active connections and routing information collection completed")
        return info
    }
    
    private func getRoutingTableInfo() -> String {
        var info = ""
        
        // Get routing table using sysctl (sandbox-safe)
        var mib: [Int32] = [Int32(CTL_NET), Int32(PF_ROUTE), 0, 0, Int32(NET_RT_DUMP), 0]
        var len: size_t = 0
        
        // First get the size
        if sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0 && len > 0 {
            // Allocate buffer and get the data
            var buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 {
                // Parse routing messages
                info += parseRoutingTable(buf, length: len)
                
                if let gateway = cachedGateway {
                    info += "Default Gateway: \(gateway)\n"
                }
            }
        }
        
        // Get interface-specific routes
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in interfaces {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? {
                info += "\nRoutes for \(bsdName):\n"
                
                // Get IPv4 configuration
                if let ipv4 = self.getIPv4ConfigForInterface(bsdName) {
                    info += ipv4
                }
            }
        }
        
        return info.isEmpty ? "Unable to retrieve routing information\n" : info
    }
    
    private func getIPv4ConfigForInterface(_ interface: String) -> String? {
        var info = ""

        if let store = dynamicStore {
            let key = "State:/Network/Service/[^/]+/IPv4" as CFString

            if let patterns = SCDynamicStoreCopyKeyList(store, key) as? [String] {
                for pattern in patterns {
                    if let dict = SCDynamicStoreCopyValue(store, pattern as CFString) as? [String: Any],
                       let interfaceName = dict["InterfaceName"] as? String,
                       interfaceName == interface {
                        
                        if let addresses = dict["Addresses"] as? [String] {
                            info += "  Addresses: \(addresses.joined(separator: ", "))\n"
                        }
                        if let router = dict["Router"] as? String {
                            info += "  Router: \(router)\n"
                        }
                        if let netmask = dict["SubnetMasks"] as? [String] {
                            info += "  Subnet Masks: \(netmask.joined(separator: ", "))\n"
                        }
                    }
                }
            }
        }
        
        return info.isEmpty ? nil : info
    }
    
    private func getNetstatOutput() -> String {
        // Without sandbox, we can get full netstat output
        let task = Process()
        task.launchPath = "/usr/sbin/netstat"
        task.arguments = ["-anp", "tcp"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        var tcpOutput = ""
        
        do {
            try task.run()
            let completed = task.waitUntilExit(timeout: 3.0)
            
            if completed {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines)
                    let relevantLines = lines.filter { line in
                        line.contains("ESTABLISHED") ||
                        line.contains("LISTEN") ||
                        line.contains("tcp4") ||
                        line.contains("tcp6")
                    }.prefix(50)
                    
                    tcpOutput = "TCP Connections:\n" + relevantLines.joined(separator: "\n")
                }
            }
        } catch {
            log("TCP netstat failed: \(error)")
        }
        
        // Also get UDP connections
        let udpTask = Process()
        udpTask.launchPath = "/usr/sbin/netstat"
        udpTask.arguments = ["-anp", "udp"]
        
        let udpPipe = Pipe()
        udpTask.standardOutput = udpPipe
        udpTask.standardError = udpPipe
        
        var udpOutput = ""
        
        do {
            try udpTask.run()
            let completed = udpTask.waitUntilExit(timeout: 3.0)
            
            if completed {
                let data = udpPipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines)
                    let relevantLines = lines.filter { line in
                        line.contains("udp4") || line.contains("udp6")
                    }.prefix(30)
                    
                    udpOutput = "\n\nUDP Connections:\n" + relevantLines.joined(separator: "\n")
                }
            }
        } catch {
            log("UDP netstat failed: \(error)")
        }
        
        return tcpOutput + udpOutput
    }
    
    private func generateDNSInfo(testHosts: [String]) -> String {
        log("Collecting DNS information...")
        var info = "--- DNS Configuration and Tests ---\n"

        // Get DNS servers from System Configuration
        info += "\nConfigured DNS Servers:\n"
        let servers = cachedDNSServers
        if servers.isEmpty {
            info += "  No DNS servers configured\n"
        } else {
            for server in servers {
                info += "  • \(server)\n"
            }
        }
        let searchDomains = cachedDNSSearchDomains
        if !searchDomains.isEmpty {
            info += "\nSearch Domains:\n"
            for domain in searchDomains {
                info += "  • \(domain)\n"
            }
        }

        // Total steps: resolve(N) + reachability(N) + TCP(N) + HTTPS(hostnamesOnly) + externalIP
        let hostnameHosts = testHosts.filter { !isIPAddress($0) }
        let totalSteps = Double(testHosts.count * 3 + hostnameHosts.count + 1)
        var step = 0.0

        // Perform DNS lookups using multiple methods
        info += "\n--- DNS Resolution Tests ---\n"

        for (index, host) in testHosts.enumerated() {
            guard !isCancelled else { break }
            phaseTracker?.update(phase: .dnsTests, progress: step / totalSteps, detail: "Resolving \(host) (\(index + 1)/\(testHosts.count))...")
            info += "\nResolving \(host):\n"

            // Method 1: Using CFHost (sandbox-friendly)
            if let results = self.performCFHostLookup(hostname: host) {
                info += "  CFHost lookup:\n"
                for ip in results {
                    info += "    • \(ip)\n"
                }
            }

            // Method 2: Using getaddrinfo (POSIX, sandbox-friendly)
            if let results = self.performGetAddrInfoLookup(hostname: host) {
                info += "  getaddrinfo lookup:\n"
                for ip in results {
                    info += "    • \(ip)\n"
                }
            }

            // Method 3: Using dscacheutil (cache lookup)
            info += self.performDSCacheUtilLookup(hostname: host)
            step += 1
        }

        // Test reverse DNS
        info += "\n--- Reverse DNS Tests ---\n"
        if let gateway = self.getDefaultGateway() {
            info += "Default Gateway (\(gateway)):\n"
            if let hostname = self.performReverseDNS(ipAddress: gateway) {
                info += "  • \(hostname)\n"
            } else {
                info += "  • No reverse DNS record\n"
            }
        }

        // Network path reachability tests using NWPathMonitor
        info += "\n\n--- Network Reachability Tests ---\n"

        // Test default gateway first
        if let gateway = self.getDefaultGateway() {
            info += "\nReachability for Default Gateway (\(gateway)):\n"
            info += self.performPathReachabilityTest(hostname: gateway)
        }

        for (index, host) in testHosts.enumerated() {
            guard !isCancelled else { break }
            phaseTracker?.update(phase: .dnsTests, progress: step / totalSteps, detail: "Reachability \(host) (\(index + 1)/\(testHosts.count))...")
            info += "\nReachability for \(host):\n"
            info += self.performPathReachabilityTest(hostname: host)
            step += 1
        }

        // NWConnection tests
        info += "\n\n--- Network Connection Tests (TCP) ---\n"
        for (index, host) in testHosts.enumerated() {
            guard !isCancelled else { break }
            phaseTracker?.update(phase: .dnsTests, progress: step / totalSteps, detail: "TCP test \(host) (\(index + 1)/\(testHosts.count))...")
            info += "\nTCP connection to \(host):443:\n"
            info += self.performNWConnectionTest(hostname: host, port: 443)
            step += 1
        }

        // URLSession HTTPS test for all hostname entries (not bare IPs)
        info += "\n\n--- HTTPS Connectivity Test ---\n"
        for (index, host) in hostnameHosts.enumerated() {
            guard !isCancelled else { break }
            phaseTracker?.update(phase: .dnsTests, progress: step / totalSteps, detail: "HTTPS test \(host) (\(index + 1)/\(hostnameHosts.count))...")
            info += "Testing HTTPS connection to \(host):\n"
            info += self.performURLSessionTest(url: "https://\(host)")
            info += "\n"
            step += 1
        }

        // External IP detection
        phaseTracker?.update(phase: .dnsTests, progress: step / totalSteps, detail: "Detecting external IP...")
        info += "\n--- External IP Address ---\n"
        info += self.getExternalIPAddress()

        log("DNS information collection completed")
        return info
    }
    
    private func performCFHostLookup(hostname: String) -> [String]? {
        let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
        var resolved = DarwinBoolean(false)
        
        // CFHost operations run on their own internal thread pool
        // This may cause priority inversion warnings but is unavoidable with this API
        CFHostStartInfoResolution(host, .addresses, nil)
        
        guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data],
              resolved.boolValue else {
            return nil
        }
        
        var results: [String] = []
        for address in addresses {
            address.withUnsafeBytes { ptr in
                let sockaddr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                
                if getnameinfo(sockaddr, socklen_t(address.count),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 {
                    results.append(String(cString: hostname))
                }
            }
        }
        
        return results.isEmpty ? nil : results
    }
    
    private func performGetAddrInfoLookup(hostname: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC // Both IPv4 and IPv6
        hints.ai_socktype = SOCK_STREAM
        
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        
        guard status == 0, let addrList = result else {
            return nil
        }
        defer { freeaddrinfo(addrList) }
        
        var results: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = addrList
        
        while let addr = current {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            
            if getnameinfo(addr.pointee.ai_addr, addr.pointee.ai_addrlen,
                          &hostname, socklen_t(hostname.count),
                          nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if !results.contains(ip) {
                    results.append(ip)
                }
            }
            
            current = addr.pointee.ai_next
        }
        
        return results.isEmpty ? nil : results
    }
    
    private func performDSCacheUtilLookup(hostname: String) -> String {
        var info = "  dscacheutil (cache) lookup:\n"
        
        // This is a simplified version - full DNS-SD would require callbacks
        let task = Process()
        task.launchPath = "/usr/bin/dscacheutil"
        task.arguments = ["-q", "host", "-a", "name", hostname]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("ip_address:") {
                        info += "    • \(line.replacingOccurrences(of: "ip_address: ", with: ""))\n"
                    }
                }
            }
        } catch {
            info += "    • Failed: \(error.localizedDescription)\n"
        }
        
        return info
    }
    
    private func performReverseDNS(ipAddress: String) -> String? {
        let addressData: Data
        if ipAddress.contains(":") {
            // IPv6
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, ipAddress, &sin6.sin6_addr) == 1 else { return nil }
            addressData = Data(bytes: &sin6, count: MemoryLayout<sockaddr_in6>.size)
        } else {
            // IPv4
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ipAddress, &sin.sin_addr) == 1 else { return nil }
            addressData = Data(bytes: &sin, count: MemoryLayout<sockaddr_in>.size)
        }

        let host = CFHostCreateWithAddress(nil, addressData as CFData).takeRetainedValue()
        var resolved = DarwinBoolean(false)

        CFHostStartInfoResolution(host, .names, nil)

        guard let names = CFHostGetNames(host, &resolved)?.takeUnretainedValue() as? [String],
              resolved.boolValue,
              !names.isEmpty else {
            return nil
        }

        return names.first
    }
    
    private func getDefaultGateway() -> String? {
        return cachedGateway
    }
    
    private func hexToMAC(_ hexString: String) -> String {
        var mac = ""
        for i in stride(from: 0, to: hexString.count, by: 2) {
            if !mac.isEmpty { mac += ":" }
            let startIndex = hexString.index(hexString.startIndex, offsetBy: i)
            let endIndex = hexString.index(startIndex, offsetBy: 2)
            mac += String(hexString[startIndex..<endIndex])
        }
        return mac
    }

    private func getBSSIDUsingAlternativeMethods() -> String? {
        // Try multiple alternative methods to get BSSID on macOS when CoreWLAN fails
        
        // Method 1: Use ioreg to get AirPort info
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-l", "-n", "AirPort_BrcmNIC", "-r"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Look for BSSID in the output
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("\"IO80211BSSID\"") {
                        // Extract BSSID from line like: "IO80211BSSID" = <data>
                        if let dataStart = line.range(of: "<"),
                           let dataEnd = line.range(of: ">"),
                           dataStart.lowerBound < dataEnd.upperBound {
                            let hexData = String(line[dataStart.upperBound..<dataEnd.lowerBound])
                                .replacingOccurrences(of: " ", with: "")
                            let bssid = hexToMAC(hexData)
                            log("BSSID from ioreg: \(bssid)")
                            return bssid.lowercased()
                        }
                    }
                }
            }
        } catch {
            log("Failed to run ioreg: \(error)")
        }
        
        // Method 3: Try alternative ioreg approach for different hardware
        let altTask = Process()
        altTask.launchPath = "/usr/sbin/ioreg"
        altTask.arguments = ["-l", "-n", "AppleBCMWLANCore", "-r"]
        
        let altPipe = Pipe()
        altTask.standardOutput = altPipe
        
        do {
            try altTask.run()
            altTask.waitUntilExit()
            
            let data = altPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("\"IO80211BSSID\"") {
                        if let dataStart = line.range(of: "<"),
                           let dataEnd = line.range(of: ">"),
                           dataStart.lowerBound < dataEnd.upperBound {
                            let hexData = String(line[dataStart.upperBound..<dataEnd.lowerBound])
                                .replacingOccurrences(of: " ", with: "")
                            let bssid = hexToMAC(hexData)
                            log("BSSID from alternative ioreg: \(bssid)")
                            return bssid.lowercased()
                        }
                    }
                }
            }
        } catch {
            log("Failed to run alternative ioreg: \(error)")
        }
        
        // Method 4: Try using networksetup command
        let networkTask = Process()
        networkTask.launchPath = "/usr/sbin/networksetup"
        networkTask.arguments = ["-getairportnetwork", "en0"]
        
        let networkPipe = Pipe()
        networkTask.standardOutput = networkPipe
        
        do {
            try networkTask.run()
            networkTask.waitUntilExit()
            
            let data = networkPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                log("networksetup output: \(output)")
                // This will give us current network name but not BSSID
            }
        } catch {
            log("Failed to run networksetup: \(error)")
        }
        
        // Method 5: Try using system_profiler with XML output for more detail
        let profilerTask = Process()
        profilerTask.launchPath = "/usr/sbin/system_profiler"
        profilerTask.arguments = ["SPAirPortDataType", "-xml"]
        
        let profilerPipe = Pipe()
        profilerTask.standardOutput = profilerPipe
        
        do {
            try profilerTask.run()
            profilerTask.waitUntilExit()
            
            let data = profilerPipe.fileHandleForReading.readDataToEndOfFile()
            if let xmlData = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] {
                // Parse the plist data to find BSSID
                for item in xmlData {
                    if let spItems = item["_items"] as? [[String: Any]] {
                        for spItem in spItems {
                            if let currentNetwork = spItem["spairport_current_network_information"] as? [String: Any] {
                                if let networks = currentNetwork["_items"] as? [[String: Any]] {
                                    for network in networks {
                                        if let bssid = network["spairport_network_bssid"] as? String {
                                            log("BSSID from system_profiler XML: \(bssid)")
                                            return bssid
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            log("Failed to parse system_profiler XML: \(error)")
        }
        
        log("Could not get BSSID from any method")
        return nil
    }
    
    private func interfaceModeString(_ mode: CWInterfaceMode) -> String {
        switch mode {
        case .station: return "Station"
        case .IBSS: return "IBSS (Ad-hoc)"
        case .hostAP: return "Host AP"
        default: return "Unknown"
        }
    }
    
    private func getMCSFromRate(rate: Double, width: CWChannelWidth, mode: CWPHYMode) -> String {
        // This is a simplified estimation - actual MCS depends on many factors
        // For 802.11n (HT) with 20MHz channel width
        let mcsTable20MHz: [(rate: Double, mcs: Int)] = [
            (6.5, 0), (13, 1), (19.5, 2), (26, 3), (39, 4), (52, 5), (58.5, 6), (65, 7)
        ]
        
        // For 802.11n (HT) with 40MHz channel width
        let mcsTable40MHz: [(rate: Double, mcs: Int)] = [
            (13.5, 0), (27, 1), (40.5, 2), (54, 3), (81, 4), (108, 5), (121.5, 6), (135, 7)
        ]
        
        let table = (width == .width40MHz) ? mcsTable40MHz : mcsTable20MHz
        
        for entry in table.reversed() {
            if rate >= entry.rate * 0.9 { // Allow 10% tolerance
                return "~\(entry.mcs) (estimated from rate)"
            }
        }
        
        return "Unable to estimate"
    }
    
    private func getDetailedWiFiInfo() -> String? {
        // Try to get more detailed info using system_profiler
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPAirPortDataType", "-detailLevel", "full"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            
            // Add timeout for system_profiler
            let timeout: TimeInterval = 5.0
            let deadline = Date().addingTimeInterval(timeout)
            
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            if task.isRunning {
                log("system_profiler timed out after \(timeout) seconds")
                task.terminate()
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output
            }
        } catch {
            log("Failed to run system_profiler: \(error)")
        }
        
        return nil
    }
    
    private func parseSystemProfilerOutput(_ output: String) -> String {
        var info = ""
        let lines = output.components(separatedBy: .newlines)
        
        // Just find and extract the raw output sections we care about
        var inWiFi = false
        var inCurrentNetwork = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Start of WiFi section
            if line.contains("Wi-Fi:") || line.contains("AirPort:") {
                inWiFi = true
                info += "\nInterface Details:\n"
                continue
            }
            
            if line.contains("Current Network Information:") {
                inCurrentNetwork = true
                inWiFi = false
                info += "\nCurrent Network Information:\n"
                continue
            }
            
            if line.contains("Other Local Wi-Fi Networks:") {
                inCurrentNetwork = false
                inWiFi = false
                continue
            }
            
            // In WiFi section - look for specific fields
            if inWiFi && trimmed.contains(":") {
                if line.contains("Supported Channels:") {
                    // Channels are on the same line with band info
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count > 1 {
                        let channelData = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        info += "  Supported Channels:\n"
                        info += self.formatChannelsWithBandInfo(channelData)
                    }
                } else if line.contains("Card Type:") ||
                   line.contains("Firmware Version:") ||
                   line.contains("MAC Address:") ||
                   line.contains("Locale:") ||
                   line.contains("Country Code:") ||
                   line.contains("Supported PHY Modes:") ||
                   line.contains("Wake On Wireless:") ||
                   line.contains("Status:") {
                    info += "  \(trimmed)\n"
                }
            }
            
            // In current network section
            if inCurrentNetwork && trimmed.contains(":") && !line.contains("Other Local") {
                info += "  \(trimmed)\n"
            }
        }
        
        return info.isEmpty ? "No additional details found\n" : info
    }
    
    private func formatChannelsWithBandInfo(_ channelData: String) -> String {
        var formatted = ""
        var band2_4GHz: [String] = []
        var band5GHz: [String] = []
        var band6GHz: [String] = []
        
        // Parse channels with format: "1 (2GHz), 2 (2GHz), ..."
        let channels = channelData.split(separator: ",")
        for channel in channels {
            let trimmed = channel.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("(2GHz)") {
                if let num = trimmed.split(separator: " ").first {
                    band2_4GHz.append(String(num))
                }
            } else if trimmed.contains("(5GHz)") {
                if let num = trimmed.split(separator: " ").first {
                    band5GHz.append(String(num))
                }
            } else if trimmed.contains("(6GHz)") {
                if let num = trimmed.split(separator: " ").first {
                    band6GHz.append(String(num))
                }
            }
        }
        
        // Format output
        if !band2_4GHz.isEmpty {
            formatted += "    2.4 GHz: " + band2_4GHz.joined(separator: ", ") + "\n"
        }
        if !band5GHz.isEmpty {
            formatted += "    5 GHz: " + band5GHz.joined(separator: ", ") + "\n"
        }
        if !band6GHz.isEmpty {
            formatted += "    6 GHz: " + band6GHz.joined(separator: ", ") + "\n"
        }
        
        return formatted
    }
    
    private func channelWidthString(_ width: CWChannelWidth) -> String {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return "Unknown"
        }
    }
    
    private func phyModeString(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax (Wi-Fi 6)"
        default: return "Unknown"
        }
    }
    
    private func securityString(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA Personal Mixed"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA Enterprise Mixed"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA3 Transition"
        default: return "Unknown"
        }
    }
    
    // MARK: - mDNS/Bonjour Service Discovery

    private func performMDNSCheck() -> String {
        var info = "--- mDNS/Bonjour Service Discovery ---\n"

        let task = Process()
        task.launchPath = "/usr/bin/dns-sd"
        task.arguments = ["-B", "_services._dns-sd._udp", "local."]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            // dns-sd runs forever; kill after 3 seconds
            let completed = task.waitUntilExit(timeout: 3.0)
            if !completed {
                task.terminate()
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                let lines = output.components(separatedBy: .newlines)
                var services: [String] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Lines with service types look like: "... _airplay._tcp. ..."
                    if trimmed.contains("._tcp.") || trimmed.contains("._udp.") {
                        // Extract service type (last column usually)
                        let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if let serviceName = components.last, serviceName.contains("._") {
                            if !services.contains(serviceName) {
                                services.append(serviceName)
                            }
                        }
                    }
                }

                if services.isEmpty {
                    info += "  No mDNS services found\n"
                } else {
                    info += "  Found \(services.count) service type\(services.count == 1 ? "" : "s"):\n"
                    for service in services.sorted() {
                        info += "    \(service)\n"
                    }
                }
            } else {
                info += "  No mDNS response received\n"
            }
        } catch {
            info += "  mDNS discovery failed: \(error.localizedDescription)\n"
        }

        return info
    }

    // MARK: - Signal Quality Labels

    private func rssiQualityLabel(_ rssi: Int) -> String {
        switch rssi {
        case _ where rssi > -50: return "Excellent"
        case -67 ... -50: return "Good"
        case -70 ... -68: return "Fair"
        case -80 ... -71: return "Weak"
        default: return "Very Weak"
        }
    }

    private func snrQualityLabel(_ snr: Int) -> String {
        switch snr {
        case _ where snr > 40: return "Excellent"
        case 25...40: return "Good"
        case 15...24: return "Fair"
        default: return "Poor"
        }
    }

    // MARK: - System Information Header

    private func generateSystemInfoHeader() -> String {
        var info = "--- System Information ---\n"

        // macOS version
        info += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"

        // Hardware model
        var modelSize: size_t = 0
        if sysctlbyname("hw.model", nil, &modelSize, nil, 0) == 0 {
            var model = [CChar](repeating: 0, count: modelSize)
            if sysctlbyname("hw.model", &model, &modelSize, nil, 0) == 0 {
                info += "Hardware Model: \(String(cString: model))\n"
            }
        }

        // Chip / CPU brand
        var cpuSize: size_t = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &cpuSize, nil, 0) == 0 {
            var cpu = [CChar](repeating: 0, count: cpuSize)
            if sysctlbyname("machdep.cpu.brand_string", &cpu, &cpuSize, nil, 0) == 0 {
                info += "Chip: \(String(cString: cpu))\n"
            }
        } else {
            // Apple Silicon doesn't expose brand_string; check for arm64
            var archSize: size_t = 0
            if sysctlbyname("hw.machine", nil, &archSize, nil, 0) == 0 {
                var arch = [CChar](repeating: 0, count: archSize)
                if sysctlbyname("hw.machine", &arch, &archSize, nil, 0) == 0 {
                    info += "Architecture: \(String(cString: arch)) (Apple Silicon)\n"
                }
            }
        }

        // Hostname
        info += "Hostname: \(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)\n"

        // System uptime
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        if days > 0 {
            info += "Uptime: \(days)d \(hours)h \(minutes)m\n"
        } else {
            info += "Uptime: \(hours)h \(minutes)m\n"
        }

        info += "\n"
        return info
    }

    // MARK: - Gateway Ping / Latency Test

    private func performPingTest(host: String, count: Int) -> String {
        var info = ""

        let task = Process()
        task.launchPath = "/sbin/ping"
        task.arguments = ["-c", "\(count)", "-W", "2000", host]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            let completed = task.waitUntilExit(timeout: TimeInterval(count * 3 + 5))

            if completed {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.contains("packet loss") || trimmed.contains("round-trip") || trimmed.contains("packets transmitted") {
                            info += "  \(trimmed)\n"
                        }
                    }
                    if info.isEmpty {
                        info = "  \(output)\n"
                    }
                }
            } else {
                task.terminate()
                info += "  Ping timed out\n"
            }
        } catch {
            info += "  Ping failed: \(error.localizedDescription)\n"
        }

        return info
    }

    // MARK: - DHCP Lease Information

    private func getDHCPLeaseInfo() -> String {
        var info = "--- DHCP Lease Information ---\n"

        let task = Process()
        task.launchPath = "/usr/sbin/ipconfig"
        task.arguments = ["getpacket", "en0"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            let completed = task.waitUntilExit(timeout: 5.0)

            if completed {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    let lines = output.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.contains("server_identifier") ||
                           trimmed.contains("lease_time") ||
                           trimmed.contains("yiaddr") ||
                           trimmed.contains("subnet_mask") ||
                           trimmed.contains("router") ||
                           trimmed.contains("domain_name_server") ||
                           trimmed.contains("domain_name") {
                            info += "  \(trimmed)\n"
                        }
                    }
                    if info == "--- DHCP Lease Information ---\n" {
                        // No recognized fields found, include raw output
                        info += output
                    }
                } else {
                    info += "  No DHCP lease data available (interface may use static IP)\n"
                }
            } else {
                task.terminate()
                info += "  ipconfig timed out\n"
            }
        } catch {
            info += "  Failed to retrieve DHCP info: \(error.localizedDescription)\n"
        }

        return info
    }

    // MARK: - Captive Portal Detection

    private func performCaptivePortalTest() -> String {
        var info = "--- Captive Portal Detection ---\n"
        let semaphore = DispatchSemaphore(value: 0)
        var resultInfo = ""

        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else {
            return info + "  Failed to create test URL\n"
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 5.0
        // Prevent automatic redirect following so we can detect captive portals
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                resultInfo = "  Test failed: \(error.localizedDescription)\n"
                resultInfo += "  Status: Unable to determine (no connectivity?)\n"
            } else if let httpResponse = response as? HTTPURLResponse,
                      let data = data,
                      let body = String(data: data, encoding: .utf8) {
                if httpResponse.statusCode == 200 && body.contains("<TITLE>Success</TITLE>") {
                    resultInfo = "  Status: No captive portal detected (direct internet access)\n"
                } else if httpResponse.statusCode >= 300 && httpResponse.statusCode < 400 {
                    resultInfo = "  Status: Captive portal DETECTED (redirect to login page)\n"
                    if let location = httpResponse.value(forHTTPHeaderField: "Location") {
                        resultInfo += "  Redirect URL: \(location)\n"
                    }
                } else {
                    resultInfo = "  Status: Possible captive portal (unexpected response)\n"
                    resultInfo += "  HTTP Status: \(httpResponse.statusCode)\n"
                }
            }
            semaphore.signal()
        }

        task.resume()

        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            task.cancel()
            resultInfo = "  Test timed out (possible network issue or captive portal blocking)\n"
        }

        session.invalidateAndCancel()
        info += resultInfo
        return info
    }

    // MARK: - Network Connectivity Tests
    
    private func performPathReachabilityTest(hostname: String) -> String {
        var info = ""
        let semaphore = DispatchSemaphore(value: 0)
        var pathStatus: NWPath.Status?
        var pathInterfaces: [NWInterface] = []
        var isExpensive = false
        var isConstrained = false
        var supportsDNS = false

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            pathStatus = path.status
            pathInterfaces = path.availableInterfaces
            isExpensive = path.isExpensive
            isConstrained = path.isConstrained
            supportsDNS = path.supportsDNS
            semaphore.signal()
        }

        let queue = DispatchQueue(label: "reachability.\(hostname)")
        monitor.start(queue: queue)

        let result = semaphore.wait(timeout: .now() + 5)
        monitor.cancel()

        if result == .timedOut {
            return "  Reachability check timed out\n"
        }

        guard let status = pathStatus else {
            return "  Failed to determine path status\n"
        }

        switch status {
        case .satisfied:
            info += "  Reachable: Yes\n"
            info += "  Connection Required: No\n"
        case .unsatisfied:
            info += "  Reachable: No\n"
            info += "  Connection Required: Yes\n"
        case .requiresConnection:
            info += "  Reachable: No\n"
            info += "  Connection Required: Yes (on-demand available)\n"
        @unknown default:
            info += "  Reachable: Unknown\n"
        }

        if status == .satisfied {
            let interfaceTypes = pathInterfaces.map { iface -> String in
                switch iface.type {
                case .wifi: return "WiFi"
                case .cellular: return "Cellular"
                case .wiredEthernet: return "Ethernet"
                case .loopback: return "Loopback"
                default: return "Other"
                }
            }
            if !interfaceTypes.isEmpty {
                info += "  Connection Type: \(interfaceTypes.joined(separator: ", "))\n"
            }
            if supportsDNS {
                info += "  DNS Support: Yes\n"
            }
        }

        if isExpensive {
            info += "  Expensive Path: Yes\n"
        }
        if isConstrained {
            info += "  Constrained Path: Yes\n"
        }

        return info
    }
    
    private func performNWConnectionTest(hostname: String, port: UInt16) -> String {
        var info = ""
        let semaphore = DispatchSemaphore(value: 0)
        let startTime = Date()
        var connectionTime: TimeInterval?
        var error: NWError?
        
        let host = NWEndpoint.Host(hostname)
        let port = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: host, port: port, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connectionTime = Date().timeIntervalSince(startTime)
                connection.cancel()
                semaphore.signal()
            case .failed(let nwError):
                error = nwError
                semaphore.signal()
            case .cancelled:
                if connectionTime == nil && error == nil {
                    semaphore.signal()
                }
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
        // Wait up to 5 seconds for connection
        let timeout = DispatchTime.now() + .seconds(5)
        if semaphore.wait(timeout: timeout) == .timedOut {
            connection.cancel()
            info += "  Connection timed out after 5 seconds\n"
        } else if let connTime = connectionTime {
            info += "  Connection established in \(String(format: "%.3f", connTime * 1000)) ms\n"
            info += "  Status: Success\n"
        } else if let err = error {
            info += "  Connection failed: \(err)\n"
        } else {
            info += "  Connection cancelled\n"
        }
        
        return info
    }
    
    private func performURLSessionTest(url: String) -> String {
        var info = ""
        let semaphore = DispatchSemaphore(value: 0)
        let startTime = Date()
        var responseTime: TimeInterval?
        var statusCode: Int?
        var error: Error?
        
        guard let testURL = URL(string: url) else {
            return "  Invalid URL\n"
        }
        
        var request = URLRequest(url: testURL)
        request.httpMethod = "HEAD"  // Use HEAD to minimize data transfer
        request.timeoutInterval = 10.0
        
        let task = self.urlSession.dataTask(with: request) { data, response, err in
            responseTime = Date().timeIntervalSince(startTime)
            
            if let httpResponse = response as? HTTPURLResponse {
                statusCode = httpResponse.statusCode
            }
            error = err
            semaphore.signal()
        }
        
        task.resume()
        
        // Wait for response
        let timeout = DispatchTime.now() + .seconds(10)
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            info += "  Request timed out after 10 seconds\n"
        } else if let respTime = responseTime {
            info += "  Response time: \(String(format: "%.3f", respTime * 1000)) ms\n"
            if let status = statusCode {
                info += "  HTTP Status: \(status)\n"
                info += "  Result: \(status >= 200 && status < 400 ? "Success" : "Failed")\n"
            }
            if let err = error {
                info += "  Error: \(err.localizedDescription)\n"
            }
        }
        
        return info
    }
    
    private func getExternalIPAddress() -> String {
        var info = ""
        let semaphore = DispatchSemaphore(value: 0)
        var externalIP: String?
        var error: Error?
        let startTime = Date()
        
        // Try multiple services for redundancy
        let ipServices = [
            "https://api.ipify.org?format=text",
            "https://ipv4.icanhazip.com",
            "https://checkip.amazonaws.com",
            "https://ipecho.net/plain"
        ]
        
        log("Detecting external IP address...")
        
        for service in ipServices {
            guard let url = URL(string: service) else { continue }
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let task = self.urlSession.dataTask(with: request) { data, response, err in
                if let data = data,
                   let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   self.isValidIPAddress(ip) {
                    externalIP = ip
                    error = nil
                    semaphore.signal()
                    return
                }
                error = err
            }
            
            task.resume()
            
            // Wait up to 5 seconds per service
            let timeout = DispatchTime.now() + .seconds(5)
            if semaphore.wait(timeout: timeout) != .timedOut {
                task.cancel()
                if externalIP != nil {
                    break
                }
            } else {
                task.cancel()
                log("Timeout getting IP from \(service)")
            }
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        
        if let ip = externalIP {
            info += "External IP: \(ip)\n"
            info += "Detection time: \(String(format: "%.3f", elapsedTime * 1000)) ms\n"
            log("External IP detected: \(ip)")
        } else {
            info += "Unable to detect external IP address\n"
            if let err = error {
                info += "Error: \(err.localizedDescription)\n"
            }
            log("Failed to detect external IP address")
        }
        
        return info
    }
    
    private func isValidIPAddress(_ string: String) -> Bool {
        // Basic validation for IPv4 and IPv6
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        
        if string.contains(":") {
            // Possible IPv6
            return string.withCString { cstring in
                inet_pton(AF_INET6, cstring, &sin6.sin6_addr) == 1
            }
        } else {
            // Possible IPv4
            return string.withCString { cstring in
                inet_pton(AF_INET, cstring, &sin.sin_addr) == 1
            }
        }
    }
}

// Extension to add timeout support to Process
extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        return !isRunning
    }
}

// Extension to help parse routing table
extension WiFiDiagnosticsCollector {
    private func parseRoutingTable(_ buffer: [UInt8], length: Int) -> String {
        var info = ""
        var offset = 0
        var routeCount = 0
        
        // Safety check
        if buffer.isEmpty || length < MemoryLayout<rt_msghdr>.size {
            return "No routing data available\n"
        }
        
        // Use simple string concatenation instead of format
        info += "Destination        Gateway            Netmask            Flags    Interface\n"
        info += String(repeating: "-", count: 80) + "\n"
        
        while offset < length {
            // Check if we have enough data for header
            if offset + MemoryLayout<rt_msghdr>.size > length {
                break
            }
            
            // Read the routing message header
            let headerData = Array(buffer[offset..<offset + MemoryLayout<rt_msghdr>.size])
            let header = headerData.withUnsafeBytes { ptr in
                ptr.load(as: rt_msghdr.self)
            }
            
            // Validate message length
            let msgLen = Int(header.rtm_msglen)
            if msgLen <= 0 || offset + msgLen > length {
                break // Invalid message length
            }
            
            // Skip if not a routing entry
            if header.rtm_type != RTM_ADD && header.rtm_type != RTM_GET {
                offset += msgLen
                continue
            }
            
            // Parse addresses after header
            let addrOffset = offset + MemoryLayout<rt_msghdr>.size
            var destination = ""
            var gateway = ""
            var netmask = ""
            var flags = ""
            let interface_idx = Int(header.rtm_index)
            
            // Format flags
            if header.rtm_flags & Int32(RTF_UP) != 0 { flags += "U" }
            if header.rtm_flags & Int32(RTF_GATEWAY) != 0 { flags += "G" }
            if header.rtm_flags & Int32(RTF_HOST) != 0 { flags += "H" }
            if header.rtm_flags & Int32(RTF_STATIC) != 0 { flags += "S" }
            if header.rtm_flags & Int32(RTF_LOCAL) != 0 { flags += "L" }
            
            // Parse socket addresses (simplified - just extract key routes)
            if addrOffset < offset + msgLen {
                // Try to extract destination and gateway addresses
                let endOffset = min(offset + msgLen, length)
                let remainingData = Array(buffer[addrOffset..<endOffset])
                
                // Look for IPv4 addresses in the data
                var i = 0
                while i < remainingData.count - 7 {
                    if remainingData[i] >= 7 && remainingData[i] <= 16 && // sa_len
                       remainingData[i+1] == UInt8(AF_INET) { // sa_family
                        
                        // Found an IPv4 address
                        let addr = String(format: "%d.%d.%d.%d", 
                                        remainingData[i+4], remainingData[i+5], 
                                        remainingData[i+6], remainingData[i+7])
                        
                        if destination.isEmpty {
                            destination = addr
                        } else if gateway.isEmpty {
                            gateway = addr
                        }
                        
                        i += Int(remainingData[i]) // Skip by sa_len
                    } else {
                        i += 1
                    }
                }
            }
            
            // Only add meaningful routes
            if !destination.isEmpty || !gateway.isEmpty {
                if destination.isEmpty { destination = "default" }
                if gateway.isEmpty { gateway = "*" }
                if netmask.isEmpty { netmask = "*" }
                
                // Get interface name
                let interfaceName = getInterfaceName(for: interface_idx) ?? "if\(interface_idx)"
                
                // Format as fixed-width columns
                let destPadded = destination.padding(toLength: 18, withPad: " ", startingAt: 0)
                let gwPadded = gateway.padding(toLength: 18, withPad: " ", startingAt: 0)
                let maskPadded = netmask.padding(toLength: 18, withPad: " ", startingAt: 0)
                let flagsPadded = flags.padding(toLength: 8, withPad: " ", startingAt: 0)
                
                info += "\(destPadded) \(gwPadded) \(maskPadded) \(flagsPadded) \(interfaceName)\n"
                routeCount += 1
            }
            
            offset += msgLen
        }
        
        info += "\nTotal routes parsed: \(routeCount)\n"
        return info
    }
    
    private func getInterfaceName(for index: Int) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        if if_indextoname(UInt32(index), &name) != nil {
            return String(cString: name)
        }
        return nil
    }
    
    // MARK: - Non-sandboxed diagnostic capabilities
    
    private func getARPTableInfo() -> String {
        var info = ""
        
        // Use arp command to get ARP table
        let task = Process()
        task.launchPath = "/usr/sbin/arp"
        task.arguments = ["-a"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            let completed = task.waitUntilExit(timeout: 3.0)
            
            if completed {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    info = output
                }
            }
        } catch {
            log("ARP command failed: \(error)")
            info = "Unable to retrieve ARP table\n"
        }
        
        return info
    }
    
    private func getNetworkStatistics() -> String {
        var info = ""
        
        // Get network interface statistics using netstat -i
        let task = Process()
        task.launchPath = "/usr/sbin/netstat"
        task.arguments = ["-i", "-b"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            let completed = task.waitUntilExit(timeout: 3.0)
            
            if completed {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    info = output
                }
            }
        } catch {
            log("Network statistics command failed: \(error)")
            info = "Unable to retrieve network statistics\n"
        }
        
        // Add per-protocol statistics
        info += "\n\n--- Protocol Statistics ---\n"
        info += getProtocolStatistics()
        
        return info
    }
    
    private func getProtocolStatistics() -> String {
        var info = ""
        
        // Get protocol statistics using netstat -s
        let task = Process()
        task.launchPath = "/usr/sbin/netstat"
        task.arguments = ["-s"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            let completed = task.waitUntilExit(timeout: 5.0)
            
            if completed {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // Filter to show only the most relevant statistics
                    let lines = output.components(separatedBy: .newlines)
                    var relevantSections = false
                    
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        
                        // Include section headers and key statistics
                        if trimmed.hasSuffix(":") && (
                            trimmed.contains("tcp") ||
                            trimmed.contains("udp") ||
                            trimmed.contains("ip") ||
                            trimmed.contains("icmp")
                        ) {
                            relevantSections = true
                            info += "\n" + line + "\n"
                        } else if relevantSections && !trimmed.isEmpty {
                            // Include statistics that contain important keywords
                            if trimmed.contains("packet") ||
                               trimmed.contains("error") ||
                               trimmed.contains("retrans") ||
                               trimmed.contains("drop") ||
                               trimmed.contains("connection") {
                                info += "  " + trimmed + "\n"
                            }
                        } else if trimmed.isEmpty {
                            relevantSections = false
                        }
                    }
                }
            }
        } catch {
            log("Protocol statistics command failed: \(error)")
            info = "Unable to retrieve protocol statistics\n"
        }
        
        return info
    }
    
    // MARK: - Security and Firewall Information
    
    private func generateSecurityInfo() -> String {
        var info = "--- Security and Firewall Information ---\n"
        
        // Check macOS firewall status
        info += "\n--- Application Firewall Status ---\n"
        info += getApplicationFirewallStatus()
        
        // Check packet filter (pf) status
        info += "\n\n--- Packet Filter (pf) Status ---\n"
        info += getPacketFilterStatus()
        
        // Check for VPN connections
        info += "\n\n--- VPN Connections ---\n"
        info += getVPNStatus()
        
        // Check for proxy settings
        info += "\n\n--- Proxy Settings ---\n"
        info += getProxySettings()
        
        return info
    }
    
    private func getApplicationFirewallStatus() -> String {
        var info = ""
        
        // Check if application firewall is enabled
        let task = Process()
        task.launchPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        task.arguments = ["--getglobalstate"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                info += output
            }
        } catch {
            log("Failed to get firewall status: \(error)")
            info += "Unable to retrieve firewall status (may require admin privileges)\n"
        }
        
        // Get firewall settings
        let settingsTask = Process()
        settingsTask.launchPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        settingsTask.arguments = ["--getallowsigned"]
        
        let settingsPipe = Pipe()
        settingsTask.standardOutput = settingsPipe
        settingsTask.standardError = settingsPipe
        
        do {
            try settingsTask.run()
            settingsTask.waitUntilExit()
            
            let data = settingsPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                info += output
            }
        } catch {
            log("Failed to get firewall settings: \(error)")
        }
        
        return info
    }
    
    private func getPacketFilterStatus() -> String {
        var info = ""
        
        // Check pf status
        let task = Process()
        task.launchPath = "/sbin/pfctl"
        task.arguments = ["-s", "info"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if output.contains("Status: Enabled") {
                    info += "Packet Filter: Enabled\n"
                    
                    // Get pf rules count
                    let rulesTask = Process()
                    rulesTask.launchPath = "/sbin/pfctl"
                    rulesTask.arguments = ["-s", "rules"]
                    
                    let rulesPipe = Pipe()
                    rulesTask.standardOutput = rulesPipe
                    rulesTask.standardError = rulesPipe
                    
                    do {
                        try rulesTask.run()
                        rulesTask.waitUntilExit()
                        
                        let rulesData = rulesPipe.fileHandleForReading.readDataToEndOfFile()
                        if let rulesOutput = String(data: rulesData, encoding: .utf8) {
                            let ruleCount = rulesOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
                            info += "Active Rules: \(ruleCount)\n"
                        }
                    } catch {
                        log("Failed to get pf rules: \(error)")
                    }
                } else {
                    info += "Packet Filter: Disabled or not configured\n"
                }
            }
        } catch {
            log("Failed to get pf status: \(error)")
            info += "Unable to retrieve packet filter status (may require root privileges)\n"
        }
        
        return info
    }
    
    private func getVPNStatus() -> String {
        var info = ""
        
        // Check for VPN connections using scutil
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--nc", "list"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                info += output
            } else {
                info += "No VPN connections configured\n"
            }
        } catch {
            log("Failed to get VPN status: \(error)")
            info += "Unable to retrieve VPN status\n"
        }
        
        return info
    }
    
    private func getProxySettings() -> String {
        var info = ""

        if let store = dynamicStore {
            let proxiesKey = "State:/Network/Global/Proxies" as CFString
            
            if let proxiesDict = SCDynamicStoreCopyValue(store, proxiesKey) as? [String: Any] {
                var hasProxy = false
                
                // Check HTTP proxy
                if let httpEnable = proxiesDict["HTTPEnable"] as? Int, httpEnable == 1,
                   let httpProxy = proxiesDict["HTTPProxy"] as? String,
                   let httpPort = proxiesDict["HTTPPort"] as? Int {
                    info += "HTTP Proxy: \(httpProxy):\(httpPort)\n"
                    hasProxy = true
                }
                
                // Check HTTPS proxy
                if let httpsEnable = proxiesDict["HTTPSEnable"] as? Int, httpsEnable == 1,
                   let httpsProxy = proxiesDict["HTTPSProxy"] as? String,
                   let httpsPort = proxiesDict["HTTPSPort"] as? Int {
                    info += "HTTPS Proxy: \(httpsProxy):\(httpsPort)\n"
                    hasProxy = true
                }
                
                // Check SOCKS proxy
                if let socksEnable = proxiesDict["SOCKSEnable"] as? Int, socksEnable == 1,
                   let socksProxy = proxiesDict["SOCKSProxy"] as? String,
                   let socksPort = proxiesDict["SOCKSPort"] as? Int {
                    info += "SOCKS Proxy: \(socksProxy):\(socksPort)\n"
                    hasProxy = true
                }
                
                // Check Auto proxy
                if let autoConfigEnable = proxiesDict["ProxyAutoConfigEnable"] as? Int, autoConfigEnable == 1,
                   let autoConfigURL = proxiesDict["ProxyAutoConfigURLString"] as? String {
                    info += "Auto Config URL: \(autoConfigURL)\n"
                    hasProxy = true
                }
                
                if !hasProxy {
                    info += "No proxy configured\n"
                }
                
                // Check exceptions
                if let exceptions = proxiesDict["ExceptionsList"] as? [String], !exceptions.isEmpty {
                    info += "Proxy Exceptions: \(exceptions.joined(separator: ", "))\n"
                }
            } else {
                info += "No proxy settings found\n"
            }
        }
        
        return info
    }
}
