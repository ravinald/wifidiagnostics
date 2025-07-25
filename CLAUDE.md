# WiFiDiagnostics - Project Documentation for Claude

## Project Overview
WiFiDiagnostics is a macOS menu bar application that collects comprehensive WiFi and network diagnostic information. The app runs in the menu bar (system tray) and generates detailed reports about the current WiFi connection, network interfaces, routing tables, DNS configuration, and more.

## Key Features
1. **Menu Bar App**: Runs as a status item in the macOS menu bar with custom icons
2. **WiFi Diagnostics**: Collects SSID, BSSID, RSSI, SNR, channel info, security type, etc.
3. **Network Information**: Interfaces, IP addresses, routing tables, active connections
4. **DNS Testing**: Performs DNS lookups using multiple methods (CFHost, getaddrinfo, dscacheutil)
5. **System Profiler Integration**: Parses detailed WiFi hardware info from system_profiler
6. **Asynchronous Operation**: All diagnostics run in background with timeouts to prevent UI blocking
7. **Report Generation**: Saves timestamped reports to Downloads folder and displays in window

## Project Structure
```
WiFiDiagnostics/
├── WiFiDiagnostics.xcodeproj     # Xcode project file
├── WiFiDiagnostics/
│   ├── WiFiDiagnosticsApp.swift  # Main app file with menu bar setup
│   ├── WiFiDiagnostics.swift     # Core diagnostics collection logic
│   ├── WiFiDiagnostics.entitlements # Sandboxing permissions
│   ├── Wifi_Report_WoB.png       # White icon for dark menu bar
│   └── Wifi_Report_BoW.png       # Black icon for light menu bar
└── CLAUDE.md                      # This file
```

## Technical Details

### Technologies Used
- **Language**: Swift 5
- **UI Framework**: SwiftUI + AppKit (NSStatusItem for menu bar)
- **System APIs**: CoreWLAN, SystemConfiguration, CFNetwork, Darwin (sysctl)
- **Minimum macOS**: Configured in Xcode project settings

### Key Components

#### WiFiDiagnosticsApp.swift
- Sets up NSStatusItem for menu bar presence
- Handles icon switching based on appearance (dark/light mode)
- Creates menu with "Generate WiFi Diagnostics" and "Quit" options
- Shows results window and saves reports to Downloads folder
- Uses UserNotifications framework for completion notifications

#### WiFiDiagnostics.swift
- **WiFiDiagnosticsCollector** class orchestrates all diagnostic collection
- Runs operations asynchronously with timeouts:
  - WiFi scan: 10 seconds
  - Overall operation: 15 seconds
  - Netstat: 3 seconds
- Collects data from multiple sources:
  - CoreWLAN for WiFi info
  - SCDynamicStore for network configuration
  - sysctl for routing tables
  - system_profiler for detailed hardware info
  - DNS resolution tests

### Sandboxing & Entitlements
The app is sandboxed with these entitlements:
- `com.apple.security.app-sandbox`: Required for Mac App Store
- `com.apple.security.device.wifi`: Access WiFi information
- `com.apple.security.network.client/server`: Network operations
- `com.apple.security.personal-information.location`: Required for WiFi scanning
- `com.apple.security.files.downloads.read-write`: Save reports to Downloads

### Common Build Issues
1. **Code signing errors**: Usually due to extended attributes on files
   - Fix: `xattr -cr .` in project directory
2. **"resource fork, Finder information, or similar detritus not allowed"**
   - Files have extended attributes that interfere with code signing
   - Fix: Remove with xattr command above

### System Profiler Parsing Challenges
The system_profiler output format for "Supported Channels" has changed over time:
- Current format: Channels on same line as label with band info: `1 (2GHz), 2 (2GHz)...`
- The parser extracts channel numbers and groups by band (2.4/5/6 GHz)
- Located in `parseSystemProfilerOutput()` and `formatChannelsWithBandInfo()`

### Future Improvements Considered
1. Real-time WiFi signal monitoring
2. Historical data tracking
3. Export to different formats (JSON, CSV)
4. Network speed tests
5. Packet capture capabilities (would require additional entitlements)

## Development Commands

### Build and Run
```bash
# Clean build folder
xcodebuild clean

# Build project
xcodebuild -project WiFiDiagnostics.xcodeproj -scheme WiFiDiagnostics build

# Remove extended attributes (if code signing fails)
xattr -cr .
```

### Testing WiFi Features
The app collects:
- Basic WiFi info via CoreWLAN (SSID, BSSID, RSSI, etc.)
- Extended info via system_profiler (MCS index, supported channels, etc.)
- Network scan of nearby access points
- Current routing table and network connections
- DNS server configuration and resolution tests

## Known Issues
1. MCS Index must be estimated from transmit rate (CoreWLAN doesn't expose it directly)
2. Some network operations may timeout in congested WiFi environments
3. Sandboxing limits access to some low-level network diagnostics

## Icon Management
- Uses two PNG icons for light/dark menu bar compatibility
- Icons should be 18x18 pixels, PNG with transparency
- `Wifi_Report_WoB.png`: White on Black (dark menu bar)
- `Wifi_Report_BoW.png`: Black on White (light menu bar)
- Automatically switches based on system appearance

## Debug Information
The app includes detailed logging with timestamps in the report's "Debug Log" section. This helps diagnose issues with data collection timeouts or failures.