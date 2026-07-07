# Ampere

A lightweight macOS menu bar app for monitoring battery status and controlling charging on Apple Silicon Macs.

<p align="center">
  <img src="ampere.png" alt="Ampere — Auto charge mode" height="560">
</p>

## Features

- **Real-time battery stats** - percentage, cycle count, health, temperature, raw charge, and battery age, plus wattage (adapter / battery / system), voltage (adapter / battery), and current (adapter / battery)
- **Charge control** - pause and resume charging via SMC
- **Auto charge management** - configurable upper/lower bounds to keep your battery in an optimal charge range
- **Micro-charge prevention** - inhibits charging between bounds after restart; only charges from below the lower bound or on explicit user request
- **Charge to upper bound** - explicitly allow charging from the current level to the upper bound
- **Discharge to upper bound** - optionally drain the battery to the target level while on AC power
- **Health check** - periodically verifies SMC state matches expected values
- **In-app updates** - checks the Homebrew cask for new versions about once a day; click **Update to X** in the panel to download, verify, install, and relaunch
- **Menu bar icon** - battery shape with live charge level and animated fill when charging or discharging
- **Pinnable popover** - pin the panel to keep it open while you work
- **Launch at login** - start automatically when you log in
- **Registration** - register with an email and registration key, bound to this Mac; the panel shows "Unregistered" until then. The registration is re-verified against the license server about once a day — network failures never clear it — and can be deregistered from the panel to move the key to another Mac.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac
- Admin privileges (for charge control features)

## Installation

### Homebrew (Recommended)

```bash
brew tap az-code-lab/taps
brew install --cask ampere
```

### Manual

Download the latest `.dmg` from the [GitHub Releases](https://github.com/az-code-lab/ampere/releases) page, open it, and drag **Ampere.app** to your Applications folder.

## Usage

### Charge Control

Pausing/resuming charging requires root access to write to the SMC. Ampere handles this as follows:

1. **On launch** - the app installs (or updates) its helper binary. If the helper is missing or outdated, macOS prompts for your admin password. If cancelled, the app exits.
2. **Setup** - a compiled helper binary (`SMCWriter`) is installed at `/usr/local/bin/az-ampere-smc` (owned by root), along with a sudoers rule at `/etc/sudoers.d/az-ampere` that allows passwordless execution of the helper. The rule is pinned to the helper's SHA-256 digest, so sudo refuses to run a swapped or tampered binary at that path.
3. **Subsequent launches** - the helper is verified at startup. If unchanged, no password is needed. After a Homebrew upgrade, the new helper is installed automatically (one password prompt).

### Auto Charge Management

When enabled, the app automatically manages charging between configurable bounds:

- **Below lower bound** - starts charging, continues until the upper bound is reached
- **Between bounds** - holds (charging inhibited); use **Charge to Upper Bound** to explicitly start charging
- **Above upper bound** - inhibits charging; use **Discharge to Upper Bound** to actively drain to the target

#### Micro-Charge Prevention

To protect battery longevity, the app prevents unnecessary short charge cycles between bounds. When the charge level is between the lower and upper bounds, charging is inhibited by default — including after an app restart or crash. The only ways charging begins are:

1. The battery drops below the **lower bound** (automatic — charges all the way to the upper bound)
2. The user toggles **Charge to Upper Bound** (explicit — charges to the upper bound, then resets)

This ensures charge cycles are always full (lower → upper) rather than fragmented micro-charges.

#### Discharge to Upper Bound

When the battery is above the upper bound, this toggle appears. When enabled, the app actively discharges the battery down to the upper bound, rather than waiting for passive drain under load.

**Note:** While discharge is active, system sleep is temporarily disabled (displayed as a warning in the UI). Sleep is restored immediately when discharge stops (either by reaching the target or toggling off). If the app is force-killed or crashes, a watchdog daemon automatically cleans up within a few seconds.

#### Charge to Upper Bound

When the battery is between the lower and upper bounds and charging is inhibited, this toggle appears. When enabled, the app allows charging until the upper bound is reached, then automatically resets the toggle and re-inhibits charging. Toggling it off mid-charge stops charging immediately and re-inhibits.

### Manual Charge Control

When auto charge management is off and a power adapter is connected, a manual **Pause Charging** / **Resume Charging** button is available.

### Behavior on Sleep/Wake and Quit/Restart

| Scenario | Sleep → Wake | Quit → Restart |
|---|---|---|
| **Charge to Upper Bound** is ON (charging in progress between bounds) | Charging continues. The SMC is already in "allow" state; the wake handler confirms this and takes no further action. Toggle stays ON until the upper bound is reached. | **Charging resumes automatically.** The "Charge to Upper Bound" toggle is persisted across restart so an in-progress charge resumes rather than parking at the current level. On launch the app sees `chargeToUpperBound = true` and leaves CHTE in the "allow" state; charging continues until the upper bound is reached, at which point the toggle clears itself. |
| **Discharge to Upper Bound** is ON (discharging above upper bound) | Discharging continues. System sleep is prevented during discharge, so normal sleep should not occur. If forced (e.g. lid close), the wake handler re-asserts the discharge SMC state. Toggle stays ON. | **Discharging resumes automatically.** The "Discharge to Upper Bound" toggle is persisted. On restart, the app clears stale SMC state, then the first refresh cycle detects the battery is still above the upper bound and restarts discharge. Toggle stays ON. |

### Settings and Safety

- **Settings persist across restarts** - auto charge management, discharge toggle, and charge bounds are saved and restored when the app relaunches.
- **Quitting the app restores system defaults** - all SMC overrides (charging inhibit, discharge) and power management changes (sleep settings) are cleared when the app exits. Your Mac returns to its normal charging and sleep behavior. If the app crashes or is force-killed, a watchdog daemon cleans up automatically within a few seconds.

### Health Check

The app periodically verifies that the actual SMC key values (`CHTE` and `CHIE`) match the expected state. If a mismatch is detected, a warning is shown in the popover and the menu bar battery icon turns orange.

#### Polling and Health Check Timing

The app polls battery state on a timer. Health checks run every poll cycle after an initial 3-cycle warm-up (to let launch cleanup settle).

|  | Popover closed (slow) | Popover open (fast) |
|---|---|---|
| **First poll** | Immediately on launch | Immediately on open |
| **Poll interval** | 60s | 10s |
| **First health check** | Cycle 4 — 3 min after launch | Cycle 4 — ~30s after open* |
| **Health check interval** | Every cycle — 60s | Every cycle — 10s |

\* The cycle counter is global and does not reset when switching between fast and slow polling. If the app has already been running, the first health check after opening the popover depends on the current cycle count.

Health checks also run immediately after revoking or re-granting admin access, so the warning clears (or appears) without waiting for the next scheduled check.

### Updates

The app checks the Homebrew cask for a newer version 5 minutes after launch and about once a day after that. When one is found, the footer shows an **Update to X** button. Clicking it:

1. Downloads the release DMG from GitHub Releases (progress shown in the footer).
2. Verifies the download: SHA-256 must match the cask, the code signature must be intact, and the Team ID must match the running app.
3. Swaps the new bundle into place (two atomic renames) and relaunches.

The relaunch takes the normal quit → restart path: SMC overrides are restored on the way down, and persisted state (auto charge management, bounds, an in-progress charge/discharge to upper bound) resumes in the new copy. If the bundled SMCWriter changed, the next launch asks for your admin password once to install the new helper — same as after a Homebrew upgrade.

If any step fails (e.g. the install location isn't writable), the error is shown next to the button and nothing is changed; `brew upgrade --cask ampere` always works as a fallback. Updating in-app leaves Homebrew's recorded version behind until the next `brew upgrade`, which harmlessly reinstalls the current release.

## Build from Source

```bash
./run.sh
```

Or manually:

```bash
swift build -c debug
.build/debug/Ampere
```

## Uninstall

### Remove the app

```bash
brew uninstall ampere
```

Or delete `Ampere.app` from Applications.

### Remove SMCWriter and admin access

Charge control installs privileged files that persist after the app is deleted:

- `/usr/local/bin/az-ampere-smc` - the SMCWriter helper binary (runs as root to write SMC keys)
- `/etc/sudoers.d/az-ampere` - the sudoers rule that allows passwordless execution of the helper
- `/Library/Application Support/az-ampere/` - state directory for the saved-sleep markers (only exists if discharge was ever used)

**From the UI:** Click **Revoke Admin Access** in the app's popover panel. This removes all of them (prompts for your admin password).

**From the command line:**

```bash
sudo rm -f /usr/local/bin/az-ampere-smc
sudo rm -f /etc/sudoers.d/az-ampere
sudo rm -rf '/Library/Application Support/az-ampere'
```

## Troubleshooting

**"Pause Charging" does nothing / no password prompt appears**

The helper binary may be corrupted. Fix by revoking and re-granting access:

1. Click **Revoke Admin Access**
2. Relaunch the app - it will prompt for your password and install a fresh helper

---

## Technical Details

This section documents the implementation details of SMC-based charge control and discharge, including the problems encountered and their solutions.

### SMC Keys

| Key | Type | Description |
|------|------|-------------|
| `CHTE` | `ui32` (4 bytes) | Charge terminate / inhibit. `0x01 00 00 00` paused, `0x00 00 00 00` allowed. |
| `CHIE` | `hex_` (1 byte) | Charge inhibit enable / discharge. `0x08` discharge, `0x00` normal. |

#### Manual Mode

| Pause button | Expected CHTE | Expected CHIE |
|---|---|---|
| Paused | `0x01 00 00 00` | `0x00` |
| Resumed | `0x00 00 00 00` | `0x00` |

#### Auto Mode — Discharge to Upper Bound OFF

| Charge level | Expected CHTE | Expected CHIE |
|---|---|---|
| >= upper bound | `0x01 00 00 00` | `0x00` |
| >= lower bound and < upper bound | `0x00 00 00 00` or `0x01 00 00 00` | `0x00` |
| < lower bound | `0x00 00 00 00` | `0x00` |

#### Auto Mode — Discharge to Upper Bound ON

| Charge level | Expected CHTE | Expected CHIE |
|---|---|---|
| > upper bound | `0x01 00 00 00` | `0x08` |
| >= lower bound and <= upper bound | `0x00 00 00 00` or `0x01 00 00 00` | `0x00` |
| < lower bound | `0x00 00 00 00` | `0x00` |

Both keys are written via IOKit's `IOConnectCallStructMethod` (selector 2) to the `AppleSMCKeysEndpoint` service (falling back to `AppleSMC`). Writing requires root privileges. Reading does not require root.

The helper binary (`SMCWriter`) is a minimal executable with no AppKit/SwiftUI dependencies. It is root-owned and not user-writable.

### Clamshell Mode and the Black Screen Problem

Writing `CHIE = 0x08` triggers a USB-C Power Delivery (PD) renegotiation, which briefly disrupts the display signal on the Thunderbolt/USB-C port. This causes a specific problem in **clamshell mode** (lid closed with external monitors):

1. The CHIE write causes a momentary display disconnect.
2. macOS detects "no displays available" and triggers clamshell sleep.
3. External monitors go permanently black until the lid is opened.

With the lid open, the internal display keeps the system awake through the brief PD disruption, so external monitors reconnect immediately.

#### Approaches that didn't work

| Approach | Result |
|----------|--------|
| `caffeinate -dis` (power assertions) | Assertions don't prevent PD-triggered clamshell sleep |
| `IOPMAssertionCreateWithName` (from root and GUI processes) | Same — assertions insufficient for hardware-level PD events |
| `IORegistryEntrySetCFProperty` / `IOConnectSetCFProperty` on `IOPMrootDomain` | Permission denied on Apple Silicon (`kIOReturnUnsupported`) |
| Writing `CH0R` instead of `CHIE` | No blackout, but doesn't actually enable discharge |
| Signal handlers (`SIGTERM`/`SIGHUP`) for cleanup in persistent process | Swift runtime is not async-signal-safe; cleanup code crashed |
| `fork()` to daemonize the watchdog | Swift/ObjC runtime is not fork-safe; child process crashed |

#### Solution

**`pmset -a sleep 0 disablesleep 1`** before the CHIE write. This disables all system sleep at the OS level, preventing macOS from sleeping during the PD disruption.

When discharge is stopped, sleep is restored to the user's original setting via `pmset -a sleep <original> disablesleep 0`. The original sleep value is saved to `/Library/Application Support/az-ampere/saved-sleep` before being overridden. The marker deliberately lives outside `/tmp`: macOS wipes `/tmp` at boot while `pmset -a` overrides persist across reboots, so a crash + reboot during discharge would otherwise lose the saved value and leave sleep permanently disabled. With the persistent marker, the next launch's cleanup finds it and restores the original setting. (Markers written to the legacy `/tmp` location by older builds are still honored.)

### Watchdog Daemon

A **watchdog daemon** is always running while the app is active. It is spawned via `posix_spawn` on launch, re-spawned after discharge stops, and also spawned by the discharge command. The daemon:

1. Runs as a detached root process (independent of the app and sudo process chain).
2. Polls the app's PID every 2 seconds.
3. If the app dies (crash, `kill -9`, Ctrl+C, etc.), the watchdog cleans up within seconds:
   - Clears `CHTE = 0x00` (allows charging)
   - Clears `CHIE = 0x00` (stops discharge)
   - Restores sleep settings via `pmset` — only if the save-sleep marker file exists (i.e. discharge had been active and overrode pmset); otherwise leaves the user's sleep settings untouched
   - Exits cleanly (no orphaned processes, no leftover files)

The watchdog must be spawned with `posix_spawn` (not `fork`) because the Swift/ObjC runtime is not fork-safe — forked children crash when using Foundation, IOKit, or Objective-C APIs. Similarly, signal handlers (`SIGTERM`/`SIGHUP`) cannot be used for cleanup because they can only call async-signal-safe C functions, not Swift/Foundation/IOKit APIs.

On app launch, any orphaned watchdog processes from a previous crash are killed via `pkill`, and CHIE/sleep settings are cleared. CHTE is set to inhibit only when auto charge management is enabled, the battery is at or above the lower bound, AND no in-progress charge-to-upper-bound is being resumed (i.e. `chargeToUpperBound` is not persisted as `true`); otherwise CHTE is cleared. A fresh watchdog is then spawned.

### Process Architecture

The app cannot write to the SMC directly — it requires root privileges. Instead, it spawns short-lived root processes (`sudo SMCWriter`) for each SMC operation, plus a long-lived watchdog daemon as a safety net that cleans up if the app dies unexpectedly.

```
Ampere (GUI, user)
  |
  |-- sudo SMCWriter inhibit                 (one-shot, root)
  |     |-- SMC write CHTE = 0x01            pause charging
  |     \-- exit(0)
  |
  |-- sudo SMCWriter allow                   (one-shot, root)
  |     |-- SMC write CHTE = 0x00            allow charging
  |     \-- exit(0)
  |
  |-- sudo SMCWriter discharge:<app-pid>     (one-shot, root)
  |     |-- pmset -a sleep 0 disablesleep 1  disable sleep (clamshell fix)
  |     |-- SMC write CHIE = 0x08            enable active discharge
  |     |-- posix_spawn SMCWriter watchdog   spawn safety net daemon
  |     \-- exit(0)
  |
  |-- sudo SMCWriter nodischarge             (one-shot, root)
  |     |-- pkill watchdog                   kill existing watchdog
  |     |-- SMC write CHIE = 0x00            disable active discharge
  |     |-- pmset restore sleep settings     only if save-sleep file exists
  |     \-- exit(0)
  |
  |-- sudo SMCWriter spawn-watchdog:<pid>    (one-shot, root)
  |     |-- posix_spawn SMCWriter watchdog   spawn safety net daemon
  |     \-- exit(0)
  |
  \-- SMCWriter watchdog:<app-pid>           (daemon, root, detached)
        |-- sleep(2) loop                    poll every 2 seconds
        |-- if app PID gone:
        |     |-- SMC write CHTE = 0x00      allow charging
        |     |-- SMC write CHIE = 0x00      stop discharge
        |     |-- pmset restore sleep        only if save-sleep file exists
        |     \-- exit(0)                    clean exit
        \-- (runs until app dies)
```

## License

MIT
