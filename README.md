# Ampere

A lightweight macOS menu bar app for monitoring battery status and controlling charging on Apple Silicon Macs.

<p align="center">
  <img src="screenshot-auto.png" alt="Ampere — Auto charge mode" height="560">
  &nbsp;&nbsp;
  <img src="screenshot-manual.png" alt="Ampere — Manual pause charging" height="560">
</p>

## Features

- **Real-time battery stats** - percentage, cycle count, health, temperature, voltage, amperage, wattage, capacity, and battery age
- **Charge control** - pause and resume charging via SMC
- **Auto charge management** - configurable upper/lower bounds to keep your battery in an optimal charge range
- **Micro-charge prevention** - inhibits charging between bounds after restart; only charges from below the lower bound or on explicit user request
- **Charge to upper bound** - explicitly allow charging from the current level to the upper bound
- **Discharge to upper bound** - optionally drain the battery to the target level while on AC power
- **Health check** - periodically verifies SMC state matches expected values
- **Update notifications** - checks for new versions via Homebrew cask
- **Menu bar icon** - battery shape with live charge level indicator
- **Pinnable popover** - pin the panel to keep it open while you work
- **Launch at login** - start automatically when you log in

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

1. **First use** - when you enable charge control, macOS prompts for your admin password.
2. **Setup** - a compiled helper binary (`SMCWriter`) is installed at `/usr/local/bin/az-ampere-smc` (owned by root), along with a sudoers rule at `/etc/sudoers.d/az-ampere` that allows passwordless execution of the helper.
3. **Subsequent use** - charge control works without password prompts.

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

When the battery is at or below the upper bound and charging is inhibited, this toggle appears. When enabled, the app allows charging until the upper bound is reached, then automatically resets the toggle and re-inhibits charging.

### Manual Charge Control

When auto charge management is off and a power adapter is connected, a manual **Pause Charging** / **Resume Charging** button is available.

### Settings and Safety

- **Settings persist across restarts** - auto charge management, discharge toggle, and charge bounds are saved and restored when the app relaunches.
- **Quitting the app restores system defaults** - all SMC overrides (charging inhibit, discharge) and power management changes (sleep settings) are cleared when the app exits. Your Mac returns to its normal charging and sleep behavior. If the app crashes or is force-killed, a watchdog daemon cleans up automatically within a few seconds.

### Health Check

The app periodically verifies that the actual SMC key values (`CHTE` and `CHIE`) match the expected state. If a mismatch is detected, a warning is shown suggesting you revoke and re-grant admin access.

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

Charge control installs two privileged files that persist after the app is deleted:

- `/usr/local/bin/az-ampere-smc` - the SMCWriter helper binary (runs as root to write SMC keys)
- `/etc/sudoers.d/az-ampere` - the sudoers rule that allows passwordless execution of the helper

**From the UI:** Click **Revoke Admin Access** in the app's popover panel. This removes both files (prompts for your admin password).

**From the command line:**

```bash
sudo rm -f /usr/local/bin/az-ampere-smc
sudo rm -f /etc/sudoers.d/az-ampere
```

## Troubleshooting

**"Pause Charging" does nothing / no password prompt appears**

The helper binary may be outdated (e.g., after rebuilding the project). Fix by revoking and re-granting access:

1. Click **Revoke Admin Access**
2. Click **Pause Charging** again - it will prompt for your password and install a fresh helper

---

## Technical Details

This section documents the implementation details of SMC-based charge control and discharge, including the problems encountered and their solutions.

### SMC Keys

| Key | Type | Description |
|------|------|-------------|
| `CHTE` | `ui32` (4 bytes) | Charge terminate / inhibit. `0x01 00 00 00` paused, `0x00 00 00 00` allowed. |
| `CHIE` | `hex_` (1 byte) | Charge inhibit enable / discharge. `0x08` discharge, `0x00` normal. |

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

When discharge is stopped, sleep is restored to the user's original setting via `pmset -a sleep <original> disablesleep 0`. The original sleep value is saved to `/tmp/.az-ampere-saved-sleep` before being overridden.

### Watchdog Daemon

A **watchdog daemon** is always running while the app is active. It is spawned via `posix_spawn` on launch, re-spawned after discharge stops, and also spawned by the discharge command. The daemon:

1. Runs as a detached root process (independent of the app and sudo process chain).
2. Polls the app's PID every 2 seconds.
3. If the app dies (crash, `kill -9`, Ctrl+C, etc.), the watchdog cleans up within seconds:
   - Clears `CHTE = 0x00` (allows charging)
   - Clears `CHIE = 0x00` (stops discharge)
   - Restores sleep settings via `pmset`
   - Exits cleanly (no orphaned processes, no leftover files)

The watchdog must be spawned with `posix_spawn` (not `fork`) because the Swift/ObjC runtime is not fork-safe — forked children crash when using Foundation, IOKit, or Objective-C APIs. Similarly, signal handlers (`SIGTERM`/`SIGHUP`) cannot be used for cleanup because they can only call async-signal-safe C functions, not Swift/Foundation/IOKit APIs.

On app launch, any orphaned watchdog processes from a previous crash are killed via `pkill`, and CHIE/sleep settings are cleared. If auto charge management is enabled and the battery is at or above the lower bound, CHTE is set to inhibit (micro-charge prevention); otherwise CHTE is cleared. A fresh watchdog is then spawned.

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
  |     |-- pmset restore sleep settings     re-enable sleep
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
        |     |-- pmset restore sleep        re-enable sleep
        |     \-- exit(0)                    clean exit
        \-- (runs until app dies)
```

## License

MIT
