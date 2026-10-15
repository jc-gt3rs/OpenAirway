# Siri & Shortcuts Integration

**Date:** 2026-07-05
**Status:** Implemented (build + unit tests passing; manual Siri/Shortcuts verification checklist below)

Airway exposes its fan control to Siri and the Shortcuts app through Apple's **App Intents** framework. This enables voice commands like:

> "Hey Siri, **Airway on Max**"
> "Hey Siri, **Airway on Chill Mode**"

…and Shortcuts automations like:

> **IF** device is charging → **Set Fan Mode** → "Charging" preset

---

## Why App Intents (and not a Siri extension)

- **No separate extension target.** On macOS, App Intents run *in-process*: if Airway is already running (normal for a menu-bar login item), the intent executes against the live app; if not, the system launches Airway first.
- **No new entitlements or Info.plist capabilities.** The legacy `NSSiriUsageDescription` / Siri capability applies only to old-style SiriKit extensions.
- **Forward-compatible with the LLM-based Siri (macOS 27+).** Apple's newer Siri grounds on App Intents metadata — phrases, entity names, and synonyms — for third-party apps. There is no separate "AI Siri" API for custom domains like fan control; building rich App Intents *is* the integration. Entity synonyms (below) exist specifically to give the LLM more to match against.

---

## The four actions

| Action | What it does | Example invocation |
|---|---|---|
| **Set Fan Mode** | Switch to Auto, Max, or any saved preset | "Airway on Max", charging automation |
| **Get Fan Status** | Report max fan RPM + system temperature | "Airway status", branch a Shortcut on RPM |
| **Increase Fan Speed** | Nudge all fans up N percentage points (default 10) | "Turn up the fans in Airway" |
| **Decrease Fan Speed** | Nudge all fans down N percentage points (default 10) | "Airway slower" |

Details:

- **Set Fan Mode** takes a `FanModeEntity` — `id` is `"system"`, `"max"`, or a preset's UUID string. Siri resolves the spoken name against entity display names *and* synonyms ("automatic", "full blast", "turbo", …).
- **Get Fan Status** returns a `FanStatusEntity` with extractable `rpm` and `temperature` values (so Shortcuts can branch on them), plus a spoken dialog. Temperature respects the user's existing °F/°C preference.
- **Increase/Decrease** work relative to the fans' *actual current speeds* (not a stale slider value), switch the app into manual mode, and clamp to the app-wide manual range of **25–100%**. The amount parameter accepts 1–75.

---

## Architecture

```
Siri / Shortcuts
      │  (App Intents, in-process)
      ▼
AirwayIntentSupport.readyApp()      ── waits ≤8s for AppDelegate.shared (cold launch)
AirwayIntentSupport.requireLicense() ── same paywall gate as the UI
      │
      ▼
FanControlViewModel (the LIVE instance)
      │  ensureFansLoaded() → applyPreset / setMaxSpeed / returnToSystemControl / adjustFanSpeed
      ▼
HelperClient.shared ── XPC ──► com.airway.helper (privileged daemon) ──► SMC
```

Key decision: intents act on the **same live `FanControlViewModel` / `LicenseManager` the popover uses** (exposed via `AppDelegate.shared`, set at the end of `applicationDidFinishLaunching`). A preset applied by Siri therefore lights up as "active" in the popover immediately, exactly like a button click.

### License gating

Every intent calls `AirwayIntentSupport.requireLicense()` before touching fan state. Users without an active trial/paid/beta license get a clear spoken/visible failure ("Airway needs an active license…") — Siri and Shortcuts are **not** a paywall bypass.

### Error handling (`AirwayIntentError`)

| Case | When | Message style |
|---|---|---|
| `appNotReady` | App didn't finish launching within ~8s | "Airway isn't ready yet…" |
| `licenseRequired` | `hasFullAccess == false` | "Airway needs an active license…" |
| `helperUnreachable` | XPC helper failed/timed out | "…Open Airway once to finish setup…" |
| `presetNotFound` | Shortcut references a deleted preset | "The preset "X" no longer exists…" |

Low-level XPC errors are remapped to `helperUnreachable` so Siri never reads out an NSError.

---

## New files (`Airway.app/Intents/`)

| File | Contents |
|---|---|
| `AirwayIntentError.swift` | Error enum + `AirwayIntentSupport` (readiness wait, license gate, error remapping) |
| `FanModeEntity.swift` | `FanModeEntity` (Auto/Max/preset) + `FanModeEntityQuery` (`EntityStringQuery` with synonym matching) |
| `SetFanModeIntent.swift` | The flagship set-mode intent |
| `GetFanStatusIntent.swift` | Status intent + `FanStatusEntity` (extractable rpm/temp) |
| `AdjustFanSpeedIntent.swift` | `IncreaseFanSpeedIntent` / `DecreaseFanSpeedIntent` |
| `AirwayShortcuts.swift` | `AppShortcutsProvider` — phrases, titles, SF Symbols; makes actions appear in Shortcuts.app automatically |

All six are registered in `project.pbxproj` (file refs `F100000040–45`, build files `A100000020–25`, group `G160000000 /* Intents */`) for the main app target only.

---

## Changes to existing code

### `FanControlViewModel.swift`
- **Bug fix:** `fans` is only populated while the popover is open (monitoring starts/stops with popover appear/disappear). Previously `applyPreset` silently no-oped when `fans` was empty — invisible in the UI, but it would have made "Hey Siri, Airway on Chill Mode" do *nothing* silently if the popover had never been opened that session. New `ensureFansLoaded()` fetches fan info directly from the helper when needed.
- `applyPreset`, `setMaxSpeed`, `returnToSystemControl` are now **`async throws`** — they still set `connectionState = .error(…)` for the UI, but also rethrow so Shortcuts/Siri receive a real failure instead of silence.
- New `adjustFanSpeed(byPercentagePoints:)` for the nudge intents, plus pure static `nudgedPercentage(from:by:)` (clamps 25–100) for testability.

### `FanControlPopoverView.swift`
- The three affected call sites now use `try? await` (the popover already surfaces failures via `connectionState`, so the thrown value is redundant there).

### `AirwayApp.swift`
- `AppDelegate.shared` (static, `private(set)`) — published at the **end** of `applicationDidFinishLaunching`, so intents that see a non-nil value are guaranteed license state has been evaluated.

### `Preset.swift`
- New pure static `PresetStore.loadPresetsFromDisk()` — reads presets from `UserDefaults` without constructing a full store (used by the entity query, which can run in a freshly launched process).
- `save()` now calls **`AirwayShortcuts.updateAppShortcutParameters()`** — App Shortcut phrases that embed an entity parameter only refresh their spoken vocabulary when told to. This makes "Hey Siri, Airway on ⟨brand-new preset⟩" work the moment the preset is created, without relaunching.

---

## Testing & verification

### Automated (passing)
- `xcodebuild build` — clean.
- `AirwayTests` suite — all green, including 7 new tests in `AirwayTests/IntentSupportTests.swift`:
  - `nudgedPercentage` clamping (upper/lower bounds, exact bounds, normal shifts)
  - `loadPresetsFromDisk` (empty, corrupt data, round-trip) — preserves and restores the developer's real presets around each test.
- Built bundle's `Contents/Resources/Metadata.appintents/extract.actionsdata` confirmed to contain all four intents — this is the exact metadata Shortcuts/Siri index.

### Manual checklist
1. Run the app, open **Shortcuts.app**, search "Airway" → all four actions appear; the *Set Fan Mode* picker lists Auto, Max, and every preset.
2. Create the automation: **New Automation → Charger → Is Connected → Set Fan Mode → "Charging"**. Plug in and confirm the preset applies and shows active in the popover.
3. Say "Hey Siri, Airway on Max" / "…on ⟨preset⟩" — confirm it works both with the app running and after quitting it (cold-launch path).
4. Temporarily force a `trialExpired` license state → intents must fail with the license message, not silently.
5. Note: App Shortcuts are indexed at install; the very first build may need a minute (or a Shortcuts.app relaunch) before phrases appear.

---

## Notes for future work

- **Negative-path unit coverage** for the intents themselves (license gate, preset-not-found) would need a seam to inject a fake `AppDelegate`/view model; intents currently reach the real `AppDelegate.shared`.
- If presets ever gain per-fan values, `FanModeEntity` needs no change (it resolves by UUID), but `SetFanModeIntent`'s dialog could mention the applied values.
- Consider a **"Toggle Fan Mode"** intent (flip Auto ⇄ last preset) if users ask for a single-button Stream Deck/Shortcuts toggle.
