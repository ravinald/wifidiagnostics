# Changelog

All notable user-facing changes to WiFi Diagnostics. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.1] - 2026-05-04

### Added
- BSSID sort: connected ESSID lists first (by RSSI), remaining ESSIDs alphabetical.
- Multi-pass network scan (3 iterations, unioned by BSSID) — single scans miss APs.
- Version + build stamp in the report header.
- Hostname/IP validation in the Hosts dialog and at the report path.
- `CFBundleDisplayName = "WiFi Diagnostics"` so Finder, Dock, and Spotlight
  show the spaced name.

### Changed
- Error log lines now name subsystem, operation, and salient input
  (e.g. `netstat: run(/usr/sbin/netstat -anp tcp) failed: ...`) for easier
  triage from pasted reports.

### Fixed
- Versioning build script no longer mutates `Info.plist` /
  `Generated/BuildID.swift` on local Release archives; runs only under CI
  (`$GITHUB_ACTIONS == true`).
- `Info.plist` DTD attribute corrected (`<plist version="1.0">`).
