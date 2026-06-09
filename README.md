# sysmonitor

`sysmonitor` is a macOS-only command-line monitor written in Swift. It reports CPU core temperatures and CPU fan speeds in a human-readable snapshot, either once or on a fixed interval.

## Features

- macOS-only implementation
- Swift Package Manager project
- one-shot or periodic monitoring
- CPU core temperature output
- CPU fan speed output
- readable text formatting with timestamps

## Requirements

- macOS
- Swift 6.2 or a compatible SwiftPM toolchain

## Build

Debug build:

```bash
swift build
```

Release build:

```bash
swift build -c release
```

Artifacts:

- `.build/debug/sysmonitor`
- `.build/release/sysmonitor`

## Run

Run once:

```bash
swift run sysmonitor
```

Run periodically:

```bash
swift run sysmonitor --interval 2
```

Run the built binary directly:

```bash
.build/debug/sysmonitor
```

Example output:

```text
sysmonitor snapshot @ 2026-06-09 15:16:12
================================================
CPU Core Temperatures
  • CPU Core Die 1: 56.3 °C
  • CPU Core Die 2: 56.0 °C

CPU Fan Speeds
  • Fan 0: 2315 RPM
  • Fan 1: 2507 RPM
```

Notes:

- Idle systems may legitimately report `0 RPM` fan speed.
- Under sustained load, fan speeds should rise and become non-zero.
- If a sensor cannot be read, the tool reports it as unavailable.

## Test

Run the packaged test executable:

```bash
swift run sysmonitor-tests
```

## Architecture

High-level structure:

```text
sysmonitor (CLI)
    │
    ├── parses arguments
    ├── triggers one-shot or periodic execution
    ▼
SysMonitorCore
    │
    ├── HardwareMonitor
    │     ├── CPU temperatures: IOHID → AppleSMC fallback
    │     └── Fan speeds: AppleSMC → IORegistry fallback
    │
    ├── MonitorSnapshot
    ├── TemperatureReading / FanReading
    └── MonitorReportFormatter
```

Package layout:

```text
Sources/
  SysMonitorCore/
    HardwareMonitor.swift
    MonitorOutput.swift
  sysmonitor/
    sysmonitor.swift

Tests/
  sysmonitor-tests/
    main.swift
```

### Components

- `Sources/sysmonitor/sysmonitor.swift`
  - CLI entry point
  - parses `--interval`
  - requests snapshots and prints reports

- `Sources/SysMonitorCore/HardwareMonitor.swift`
  - collects sensor data from macOS system interfaces
  - reads CPU temperatures and fan speeds
  - normalizes sensor labels

- `Sources/SysMonitorCore/MonitorOutput.swift`
  - defines snapshot and reading models
  - formats output for human-readable display

### Sensor paths

- CPU temperatures
  1. Read from the HID event system when available
  2. Fall back to AppleSMC when needed

- Fan speeds
  1. Read from AppleSMC using `FNum`, `F0Ac`, `F1Ac`, and related keys
  2. Fall back to IORegistry if AppleSMC fan reads are unavailable

## Design notes

- The project is intentionally macOS-specific.
- Hardware access is isolated in `SysMonitorCore` so the CLI stays simple.
- Apple interfaces can vary across Mac models and macOS versions, so the monitor uses fallback paths where possible.
# sysmonitor-trae
