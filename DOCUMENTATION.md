# Airway — Technical Documentation

This document provides an in-depth technical reference for the Airway codebase, covering architecture, SMC internals, XPC communication, and UI components.

---

## Architecture

Airway is composed of two build targets that communicate over XPC:

```
┌───────────────────────────────────────────────────┐
│                Airway.app (SwiftUI)                │
│                                                     │
│  AirwayApp ── AppDelegate                          │
│      │            │                                │
│      │       NSStatusItem + NSPopover              │
│      │            │                                │
│      ├── LicenseManager ◄── KeychainStore          │
│      │        │      ▲                             │
│      │        │      └── TokenVerifier (ES256 JWT) │
│      │        └── LicenseAPIClient ── MachineID    │
│      │                                              │
│  FanControlViewModel ◄──── UserDefaults             │
│      │       │                                      │
│      │       └── PresetStore ◄──── UserDefaults     │
│      │                                              │
│  FanControlPopoverView                              │
│      ├── FanSliderRow (per fan)                     │
│      ├── GlassButtonStyle (Auto/Manual/Max)         │
│      ├── PresetManagerView / SymbolPickerPopover    │
│      ├── License views (Trial/Paywall/Locked/...)   │
│      └── settingsFooter (Options panel)             │
│                                                      │
│  HelperClient (XPC client, singleton)               │
│      │                                              │
└──────┼──────────────────────────────────────────────┘
       │  NSXPCConnection (Mach service)
       ▼
┌─────────────────────────────────────────────┐
│         com.airway.helper (Daemon)          │
│                                             │
│  main.swift ── NSXPCListener                │
│      │                                      │
│  HelperService (HelperProtocol)             │
│      │                                      │
│  SMCWrapperObjC (Objective-C)               │
│      │                                      │
│  SMC.c / SMC.h (IOKit raw calls)            │
│                                             │
└─────────────────────────────────────────────┘
```

### Airway.app — Application Target

The main SwiftUI application. It provides the user interface (menu bar item, popover, about window) and communicates with the helper over XPC.

| File | Purpose |
|---|---|
| `AirwayApp.swift` | App entry point, `AppDelegate` with `NSStatusItem`/`NSPopover` setup, status bar rendering, `AboutWindowController`, and graceful shutdown logic. Owns the `LicenseManager` instance and triggers `checkLicenseOnLaunch()`. |
| `ViewModels/FanControlViewModel.swift` | `@Observable` view model. Manages fan state, slider percentages, active mode, connection state, and preferences stored in `UserDefaults`. Handles periodic polling (2s interval) and debounces refreshes during in-flight changes. Owns a `PresetStore` and applies/clears the active preset as fan state changes. |
| `Views/FanControlPopoverView.swift` | Primary popover UI. Contains the header with animated fan icon, fan slider rows, mode buttons (Auto/Manual/Max), the preset picker row, and an expandable options panel with settings toggles. Switches its content based on `LicenseManager.state` (trial entry, paywall, locked, verification warning, or normal fan UI). |
| `Views/VisualEffectBackground.swift` | `NSViewRepresentable` wrapper for `NSVisualEffectView` to provide vibrancy/blur backgrounds. |
| `Views/PresetManagerView.swift` | Sheet UI for creating, editing, reordering, and deleting fan presets. Includes an embedded `SymbolPickerPopover` for choosing a preset's SF Symbol. |
| `Views/SymbolPickerPopover.swift` | Standalone SF Symbol picker popover used when assigning an icon to a preset. |
| `Views/LicenseViews.swift` | SwiftUI views for the licensing flow: `TrialEmailEntryView`, `TrialBannerView`, `PaywallView`, `ActivationSuccessBannerView`, `VerificationWarningView`, `LicenseLockedView`, and the shared `LicenseButtonStyle`. |
| `Helper/HelperClient.swift` | Singleton XPC client. Manages `NSXPCConnection` lifecycle, helper installation/repair via `SMAppService` and `SMJobBless`, and exposes async Swift methods (`fetchFanInfo`, `fetchSystemTemperature`, `setMode`). Includes a 15-second XPC timeout mechanism. |
| `Shared/HelperProtocol.swift` | `@objc` protocol defining the XPC interface (`getFanInfo`, `getSystemTemperature`, `setFanMode`, `getVersion`). Also contains `FanInfoDTO` — an `NSSecureCoding`-compliant data transfer object — and the `FanMode` enum. Shared by both targets. |
| `Shared/Preset.swift` | `Preset` model (name, mode — RPM or percentage —, value, optional SF Symbol) and `PresetStore`, an `ObservableObject` that persists presets and the active preset ID to `UserDefaults` as JSON. |
| `License/LicenseManager.swift` | `ObservableObject` state machine driving license/trial/paywall UI. States: `loading`, `noToken`, `beta`, `trial(daysRemaining:)`, `trialExpired`, `paid`, `paidVerificationPending`, `paidLocked`, `activating`. Verifies tokens locally first, calls the server only when required (near-expiry paid tokens, activation, trial start), and enforces a 3-day grace period with exponential-backoff rate limiting on activation attempts. |
| `License/LicenseAPIClient.swift` | Async/await client for `https://jc.didthat.lol/airway`. Endpoints: `/license/trial/start`, `/license/activate`, `/license/verify`. Distinguishes `networkFailure` (soft, retryable) from `serverRejection` (authoritative denial) via `LicenseAPIError`. |
| `License/TokenVerifier.swift` | Verifies ES256-signed JWT license tokens against an embedded P-256 public key (via CryptoKit) and decodes the payload into a `LicenseToken`. Tokens that fail signature verification are discarded. |
| `License/KeychainStore.swift` | Minimal Keychain wrapper (`kSecClassGenericPassword`) for saving, loading, and deleting the license JWT, accessible after first unlock. |
| `License/MachineID.swift` | Derives a stable hardware identifier from IOKit's `IOPlatformUUID`, used to bind licenses to a machine. |

### com.airway.helper — Privileged Helper Daemon

A privileged daemon that communicates directly with the hardware through IOKit. Runs as root to access the SMC.

| File | Purpose |
|---|---|
| `main.swift` | Sets up `NSXPCListener` on the `com.airway.helper` Mach service and runs the run loop. |
| `HelperService.swift` | Implements `HelperProtocol`. Contains the core fan control logic including the multi-phase "wake override" sequence for setting fan speeds. |
| `SMCClient/SMC.c` | Low-level C interface to the AppleSMC IOKit driver. Provides `SMCOpen`, `SMCClose`, `SMCReadKey`, `SMCWriteKey`, and `SMCKeyToUInt32`. |
| `SMCClient/SMC.h` | Header defining SMC data structures (`SMCVal_t`, `SMCKeyData_t`) and function prototypes. |
| `SMCClient/SMCWrapperObjC.m` | Objective-C wrapper around `SMC.c`. Handles multiple SMC data formats (`fpe2`, `sp78`, `flt`), fan speed reading/writing, force bit manipulation, the `Ftst` diagnostic unlock, and the all-in-one wake override sequence. |
| `SMCClient/SMCWrapperObjC.h` | Objective-C header exposing the `SMCWrapperObjC` interface to Swift via a module map. |
| `SMCClient/module.modulemap` | Clang module map exposing `SMCBridge` (C) and `SMCWrapperObjC` (Obj-C) modules to Swift. |

---

## SMC Communication

Airway communicates with the Apple System Management Controller via IOKit's `AppleSMC` driver. The SMC exposes hardware state through four-character keys:

### Key Reference

| Key | Type | Description |
|---|---|---|
| `FNum` | `ui8` | Number of fans detected |
| `F%dAc` | `fpe2`/`flt` | Current actual fan speed (RPM) |
| `F%dMn` | `fpe2`/`flt` | Minimum fan speed (RPM) |
| `F%dMx` | `fpe2`/`flt` | Maximum fan speed (RPM) |
| `F%dTg` | `fpe2`/`flt` | Target fan speed (RPM) — writable |
| `F%dMd` | `ui8` | Per-fan manual mode flag (M1–M4: uppercase) |
| `F%dmd` | `ui8` | Per-fan manual mode flag (M5+: lowercase) |
| `FS! ` | `ui16` | Force-override bitmask (one bit per fan) |
| `Ftst` | `ui8` | Diagnostic unlock flag (M3/M4, tells thermalmonitord to yield) |
| `Te05`, `Tp01`, etc. | `sp78`/`flt` | Temperature sensor readings (°C) |

### Data Type Encoding

The SMC uses several fixed-point and floating-point encodings:

- **`fpe2`** — Unsigned 14.2 fixed-point. Value = raw `UInt16` / 4.0
- **`sp78`** — Signed 8.8 fixed-point. Value = raw `SInt16` / 256.0
- **`flt `** — Standard IEEE 754 single-precision float (32-bit)
- **`ui16`** — Unsigned 16-bit integer (big-endian)

### Wake Override Sequence

Setting fan speed on modern Apple Silicon requires a multi-phase sequence to overcome `thermalmonitord` enforcement:

1. **Phase 0** — Detect the correct mode key casing (`F%dMd` vs `F%dmd`) for the current hardware generation.
2. **Phase 1** — Write `Ftst=1` to signal `thermalmonitord` to yield fan control (M3/M4 only; skipped on M1/M5+ where Ftst is absent).
3. **Phase 2** — Read-modify-write the `FS! ` bitmask to set the force bit for the target fan.
4. **Phase 3** — Write the per-fan mode key to manual (`1`) with retry loop (up to 6 seconds on M3/M4 while thermalmonitord yields).
5. **Phase 4** — Sleep 200ms for the SMC firmware to register the state transition.
6. **Phase 5** — Write the target RPM to `F%dTg` (with one retry on failure).
7. **Phase 6** — Verify the write by reading back `F%dTg` and `F%dAc`.

### Releasing Control

Returning to system control involves:

1. Writing `Ftst=0` to re-enable `thermalmonitord`.
2. Clearing all bits in the `FS! ` bitmask.
3. Clearing per-fan mode keys (`F%dMd` / `F%dmd`) for each fan.
4. Releasing individual fan overrides.

---

## XPC Communication

The app and helper communicate over a privileged Mach XPC connection.

### Protocol

```swift
@objc protocol HelperProtocol {
    func getFanInfo(reply: @escaping ([FanInfoDTO], Error?) -> Void)
    func getSystemTemperature(reply: @escaping (Double, Error?) -> Void)
    func setFanMode(_ mode: FanMode, percentages: [NSNumber], reply: @escaping (Error?) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
}
```

### Serialization

`FanInfoDTO` conforms to `NSSecureCoding` for safe XPC serialization. Custom XPC interface class whitelists are configured in `makeHelperInterface()` to allow `[FanInfoDTO]` and `[NSNumber]` arrays across the connection boundary.

### Helper Installation

Airway uses a dual-path installation strategy:

1. **`SMAppService.daemon(plistName:)`** — Modern macOS 13+ API. Registers the helper via `com.airway.helper.plist`.
2. **`SMJobBless`** — Legacy fallback with administrator authorization. Used when `SMAppService` registration fails or when the helper needs approval in Login Items.

On launch, the app attempts installation and prompts for administrator credentials if needed.

---

## User Interface

### Menu Bar

The status item displays a fan icon with optional RPM and temperature readouts. The rendering uses `NSImage` compositing to combine the SF Symbol fan icon with monospaced-digit text. Updates every 2 seconds.

Display options (configured in the Options panel):

| Option | Effect |
|---|---|
| Show RPM in Menu Bar | Displays highest fan RPM next to the icon |
| Show Temp in Menu Bar | Displays system temperature next to the icon |
| Both enabled | Stacks temperature over RPM in a compact two-line layout |

### Popover

The popover uses transient behavior and includes debounce logic (250ms) to prevent re-opening when clicking the status bar button to dismiss.

**Mode Buttons** use a custom `GlassButtonStyle` with spring press animations and accent color tinting.

**Preset Row** shows saved presets (see [Fan Presets](#fan-presets)) as tappable chips; selecting one applies it and highlights it as active, deselecting when the mode/sliders are changed manually.

**Fan Sliders** feature:
- Real-time RPM readout per fan
- Percentage display
- Haptic feedback on value changes
- Spring animations for smooth slider movement
- Fine-tune toggle (1% vs 25% step granularity)

**Options Panel** expands with an animated chevron and includes toggles for:
- Show RPM in Menu Bar
- Show Temp in Menu Bar
- Launch at Login
- Use Fahrenheit
- Fine Tune Manual Override
- About / Quit buttons with hover effects

### About Window

A minimal, translucent window with `NSVisualEffectView` background showing the app icon, name, version, and copyright. Uses a custom `NSWindowController` singleton.

---

## Editions

Airway builds in two editions from the same source. `AirwayEdition.isLicensed` (in `License/LicenseManager.swift`) reads the `LICENSED` Swift compilation condition on the app target:

| | Open edition (OpenAirway default) | Licensed edition (`LICENSED`) |
|---|---|---|
| Features | Everything unlocked | Everything, after trial or license |
| License state | Always `unlocked`, no keychain or server calls | Full state machine below |
| Crash reports and in-app feedback | Off. "Send Feedback" opens the OpenAirway GitHub issues | On |
| Sparkle updates | Off. Update by pulling and rebuilding | On |
| Network traffic to the Airway server | None | License, telemetry, updates |

To build the licensed edition, add `LICENSED` to the Airway target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Leave it out for the open edition.

---

## Licensing

The licensed edition gates full access behind a trial/license system built on locally-verified JWTs.

### State Machine

`LicenseManager` (`License/LicenseManager.swift`) drives all licensing UI via a `LicenseState` enum:

| State | Meaning | Full Access? |
|---|---|---|
| `unlocked` | Open edition, no license needed | Yes |
| `loading` | Checking keychain on launch | No |
| `noToken` | No token found — prompt for trial email | No |
| `beta` | Beta token — forever valid, no server calls | Yes |
| `trial(daysRemaining:)` | Active trial | Yes |
| `trialExpired` | Trial ended — paywall shown | No |
| `paid` | Active paid license | Yes |
| `paidVerificationPending(String)` | Verification failed but within grace period — soft warning | Yes |
| `paidLocked` | Grace period exceeded — hard lock | No |
| `activating` | Activation request in flight | No |

On launch, `checkLicenseOnLaunch()` loads the token from the Keychain, verifies its ES256 signature via `TokenVerifier`, and evaluates the state. Beta tokens never touch the network. Paid tokens with more than 7 days until expiry skip server verification entirely; otherwise a background verification call runs while access continues uninterrupted (network failures are never treated as denials — only an explicit `valid: false` from the server is).

### Grace Period & Rate Limiting

- Paid license verification failures (network or server) are tracked in `UserDefaults`. The app stays in `paidVerificationPending` for up to **3 days** of consecutive failures before hard-locking to `paidLocked`.
- A periodic background task retries verification every **4 hours** while a paid token is within 7 days of expiry.
- License activation (`activateLicense`) enforces exponential backoff on repeated failed attempts (2s, 4s, 8s, 16s, capped at 30s) to deter brute-force attempts against the paywall.

### Token Verification

Tokens are ES256-signed JWTs verified locally against an embedded P-256 public key (`TokenVerifier.swift`, via CryptoKit) — the app never trusts token claims without a valid signature. A token that fails verification is discarded from the Keychain and treated as `noToken`.

### Server API

`LicenseAPIClient` talks to `https://jc.didthat.lol/airway`:

| Endpoint | Purpose |
|---|---|
| `POST /license/trial/start` | Starts a trial for an email + machine ID, returns a JWT |
| `POST /license/activate` | Activates a paid license key, returns a JWT |
| `POST /license/verify` | Re-verifies an existing token, optionally returns a refreshed JWT |

Licenses are bound to a machine via `MachineID.platformUUID` (IOKit's `IOPlatformUUID`).

---

## Telemetry & Feedback

The licensed edition reports crashes and collects feedback, both POSTed to the license server host (`https://jc.didthat.lol/airway`). Telemetry is best-effort and fire-and-forget — a telemetry failure never blocks the UI or affects fan control.

| File | Purpose |
|---|---|
| `Telemetry/TelemetryReporter.swift` | `AirwayLog` (os.Logger handles), `TelemetryContext` (app/OS/machine snapshot), `TelemetryReporter` (posts feedback + crash reports, persists crashes to Application Support for upload on next launch), and `CrashCatcher` (installs `NSSetUncaughtExceptionHandler`). |
| `Views/FeedbackView.swift` | "Send Feedback" sheet — category (bug/idea/other), message, optional contact email; attaches app/OS context and a recent os_log tail. Opened from the Options panel. |

- **Crashes**: `CrashCatcher.install()` (called in `applicationDidFinishLaunching`) captures uncaught `NSException`s and writes them to `Application Support/Airway/pending-crash.json`. On the next launch, `flushPendingCrashReport()` uploads and clears it. (Pure-Swift `fatalError`s and signals are not captured — an accepted beta limitation.)
- **Feedback**: `TelemetryReporter.sendFeedback(...)` POSTs to `/telemetry/feedback`; the sheet awaits the result to show success/failure.
- **Endpoints** the server must implement: `POST /telemetry/crash` and `POST /telemetry/feedback` (see `scripts/SERVER-SPEC.md`). Both return any `2xx` on success.

---

## Fan Presets

`Shared/Preset.swift` defines a `Preset` (name, `PresetMode` — `.rpm` or `.percentage` —, value, optional SF Symbol) and `PresetStore`, an `ObservableObject` owned by `FanControlViewModel` that persists presets and the active preset ID to `UserDefaults` as JSON.

- Preset names are capped at 30 characters.
- RPM presets are validated against the fan's actual min/max RPM (from `FanInfoDTO`); percentage presets must fall between 25% and 100%, matching the manual override safety floor.
- Applying a preset sets `activeMode` accordingly; any manual slider/mode change clears `activePresetID` so the UI never shows a stale preset as active.
- `Views/PresetManagerView.swift` provides the CRUD sheet (add/edit/reorder/delete), with `SymbolPickerPopover` for choosing each preset's icon.

---

## Hardware Safety & Manual Override

Airway enforces a hard minimum of **25%** for fan speeds when using Manual Override. 

**Why 25%?** Forcing a Mac's fan completely off (0%) while overriding the system's thermal management can lead to rapid overheating and potential thermal damage to the CPU/GPU, especially if the user forgets they have overridden the default controls. The 25% baseline ensures there is always active airflow to protect the hardware. Additionally, the SMC itself typically enforces a hardware-defined minimum RPM that it won't let the fan drop below.

**Disclaimer:** By using the manual override features of this application, users must be aware of the inherent risks of overriding macOS's default thermal management. The application provides these tools for power users but relies on the user to monitor temperatures responsibly.

---

## Project Structure

```
airway/
├── Airway.app/                        # Main application target
│   ├── AirwayApp.swift                # App entry, AppDelegate, About window
│   ├── Info.plist                     # App metadata, LSUIElement, SMPrivilegedExecutables
│   ├── Airway.entitlements            # App sandbox entitlements
│   ├── Assets.xcassets/               # App icons and image assets
│   ├── Views/
│   │   ├── FanControlPopoverView.swift  # Main popover UI
│   │   ├── VisualEffectBackground.swift # NSVisualEffectView wrapper
│   │   ├── PresetManagerView.swift      # Preset CRUD sheet
│   │   ├── SymbolPickerPopover.swift    # SF Symbol picker for presets
│   │   └── LicenseViews.swift           # Trial/paywall/locked license UI
│   ├── ViewModels/
│   │   └── FanControlViewModel.swift    # Observable view model
│   ├── Helper/
│   │   └── HelperClient.swift           # XPC client + helper installer
│   ├── License/
│   │   ├── LicenseManager.swift         # License state machine
│   │   ├── LicenseAPIClient.swift       # Trial/activate/verify network calls
│   │   ├── TokenVerifier.swift          # ES256 JWT signature verification
│   │   ├── KeychainStore.swift          # Keychain persistence for the license token
│   │   └── MachineID.swift              # IOPlatformUUID-based machine identifier
│   └── Shared/
│       ├── HelperProtocol.swift         # XPC protocol + DTOs (shared by both targets)
│       └── Preset.swift                 # Preset model + PresetStore
│
├── com.airway.helper/                 # Privileged helper daemon target
│   ├── main.swift                     # XPC listener entry point
│   ├── HelperService.swift            # HelperProtocol implementation
│   ├── Info.plist                     # Helper metadata, SMAuthorizedClients
│   ├── com.airway.helper.plist        # launchd plist for SMAppService
│   └── SMCClient/
│       ├── SMC.c                      # Raw IOKit SMC calls
│       ├── SMC.h                      # SMC data structures
│       ├── SMCWrapperObjC.m           # Obj-C SMC wrapper with wake override
│       ├── SMCWrapperObjC.h           # Obj-C interface header
│       └── module.modulemap           # Clang module map for Swift interop
│
├── Airway.xcodeproj/                  # Xcode project
├── logos/                             # App logo exports
├── LICENSE                            # Proprietary license
├── DOCUMENTATION.md                   # This file
└── README.md                          # Project overview
```
