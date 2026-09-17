# Ampere

A lightweight macOS menu bar app for monitoring battery status and controlling charging on Apple Silicon Macs.

<p align="center">
  <img src="ampere.png" alt="Ampere — Auto charge mode" height="560">
</p>

## Features

- **Real-time battery stats** - percentage, cycle count, health, temperature, raw charge, and battery age, plus wattage (adapter / battery / system), voltage (adapter / battery), and current (adapter / battery)
- **Charge control** - pause and resume charging via SMC
- **Auto charge** - configurable upper/lower bounds to keep your battery in an optimal charge range; custom bounds are the licensed feature, and an unregistered copy runs the default 40 to 60% range
- **Micro-charge prevention** - inhibits charging between bounds after restart; only charges from below the lower bound or on explicit user request
- **Sleep-safe charging** - an in-progress charge never overshoots the upper bound while the Mac sleeps: between the bounds it pauses just before sleep and resumes on wake; below the lower bound the Mac is kept awake until the charge completes
- **Charge to upper bound** - explicitly allow charging from the current level to the upper bound
- **Charge to full** - one-shot full charge without touching the configured bounds; normal management resumes when full
- **Discharge to upper bound** - optionally drain the battery to the target level while on AC power
- **Health check** - periodically verifies SMC state matches expected values, and re-applies the expected charging state if it drifted
- **macOS 27 support** - on firmware that no longer exposes the charge-inhibit key, the app holds the battery through macOS's own charge limit instead, with the same bounds and toggles (see Firmware without CHTE below)
- **In-app updates** - checks the Homebrew cask for new versions about once a day; a small blue badge dot on the menu bar icon signals a pending update, and clicking **Update to X** in the panel downloads, verifies, installs, and relaunches
- **Menu bar icon** - battery shape with live charge level and animated fill when charging or discharging; hovering it shows the current charge and status (e.g. "85% — Charging — 32m to 80%"); the percent readout beside it can be hidden (Settings → Percent in Menu Bar) for a narrower menu bar footprint
- **Pinnable popover** - pin the panel to keep it open while you work, or drag it off the menu bar to float it as a window you can place anywhere
- **Keep awake** - optionally prevent idle sleep while on AC power, for a set duration or until turned off (the Keep Awake row on the panel); a standard power assertion, so it needs no admin rights and is auto-released on quit or crash
- **Launch at login** - start automatically when you log in
- **Registration** - register with an email and registration key, bound to this Mac; the panel shows "Unregistered" until then. The registration is re-verified against the license server about once a day — network failures never clear it — and can be deregistered from the panel to move the key to another Mac. Registering unlocks custom charge bounds; every other feature works the same unregistered.

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

1. **On launch** - the app installs (or updates) its helper binary. If the helper is missing, outdated, or not authorized for the current account, macOS prompts for your admin password. If cancelled, the app exits. If the helper cannot be installed at all, for example because the helper directory is writable by other users, the alert explains why instead of asking for a password.
2. **Setup** - a compiled helper binary (`SMCWriter`) is installed at `/Library/PrivilegedHelperTools/az-ampere-smc` (owned by root), along with a sudoers rule at `/etc/sudoers.d/az-ampere` that allows passwordless execution of the helper. The rule is pinned to the helper's SHA-256 digest. The helper and every directory leading to it are checked for root ownership, write permissions, ACLs, and symlinks, preventing replacement by an ordinary app.
3. **Subsequent launches** - the helper and the current account's passwordless authorization are verified at startup. If both are current, no password is needed. After a Homebrew upgrade, the new helper is installed automatically (one password prompt).
4. **Cleanup job** - once this account can run the helper, the app registers a root launchd job (`/Library/LaunchDaemons/com.az-code-lab.ampere.cleanup.plist`) that watches the installed `Ampere.app`. Registration goes through the same passwordless rule, so it never prompts. If the bundle stays gone for two minutes and no copy of Ampere is running, the job has the helper restore charging and sleep settings and remove the helper, the sudoers rule, the state directory, the job itself, and every account's preferences, caches, and saved window state, so dragging the app to the Trash or `brew uninstall` leaves nothing behind (see Uninstall). macOS shows a one-time "Background Items Added" notice when the job is first registered and lists it under Ampere in System Settings > General > Login Items & Extensions. Moving `Ampere.app` re-registers the job at the next launch; if the old location stays empty for two minutes before that launch, the helper is uninstalled and the next launch asks for the password again.

Upgrading from the former `/usr/local/bin/az-ampere-smc` location migrates the helper during that same administrator prompt. The replacement is verified before installation, restores the previous session's charging and sleep state, and retires the old helper and watchdogs. A restore failure does not block the installation; the app's launch cleanup and the watchdog retry it. Preferences, charge bounds, and registration stay intact; no manual migration is needed.

> **Note:** Admin access is granted per macOS user account: the sudoers file holds one line per account that has granted it. Another account on the same Mac is asked for its password once, after which both stay authorized, and an upgrade refreshes every line so only the first account to launch the new version is prompted. Revoke removes only the current account's line and deletes the helper once no account remains. Only one running copy of Ampere manages charge control at a time: with fast user switching, a copy launched while another account's copy is already running shows battery information but stands by, and takes over once that copy quits.

### Auto Charge

When enabled, the app automatically manages charging between configurable bounds:

- **Below lower bound** - starts charging, continues until the upper bound is reached
- **Between bounds** - holds (charging inhibited); use **Charge to Upper Bound** to explicitly start charging
- **Above upper bound** - inhibits charging; use **Discharge to Upper Bound** to actively drain to the target

#### Charge Bounds and Registration

Custom charge bounds are the licensed feature. An unregistered copy runs the default 40 to 60% range: the slider still shows the bounds, but the draggers are locked (their tooltips say so), and a **Register to change** link beneath the slider opens the registration window. Everything else, including auto charge itself, micro-charge prevention, charge and discharge to upper bound, charge to full, and keep awake, works the same unregistered.

Registering unlocks the draggers immediately. If the registration lapses (deregistered from the panel, the key registered on another Mac, or the daily verify reporting the license revoked), both bounds return to 40 to 60% at once and the draggers lock again; the state machine treats that like any other bound change, so a charge already past 60% is inhibited on the next poll. The reset is also applied at launch, so a custom range persisted by a lapsed registration never resurfaces after a restart. Network failures never lapse a registration, so an offline Mac keeps its custom bounds.

#### Micro-Charge Prevention

To protect battery longevity, the app prevents unnecessary short charge cycles between bounds. When the charge level is between the lower and upper bounds, charging is inhibited by default — including after an app restart or crash. The only ways charging begins are:

1. The battery drops below the **lower bound** (automatic — charges all the way to the upper bound)
2. The user toggles **Charge to Upper Bound** (explicit — charges to the upper bound, then resets)

This ensures charge cycles are always full (lower → upper) rather than fragmented micro-charges.

#### Discharge to Upper Bound

When the battery is above the upper bound, this toggle appears. When enabled, the app actively discharges the battery down to the upper bound, rather than waiting for passive drain under load.

**Note:** While discharge is active, system sleep is temporarily disabled (displayed as a warning in the UI). Sleep is restored immediately when discharge stops (either by reaching the target or toggling off). If the app is force-killed or crashes, a watchdog daemon automatically cleans up within a few seconds.

When a discharge stops, the app explicitly re-writes the charging-inhibit key: on some Macs the firmware clears it while discharge is active, and without the re-write charging would silently resume past the upper bound.

#### Charge to Upper Bound

When the battery is between the lower and upper bounds and charging is inhibited, this toggle appears. When enabled, the app allows charging until the upper bound is reached, then automatically resets the toggle and re-inhibits charging. Toggling it off mid-charge stops charging immediately and re-inhibits.

#### Charge to Full

A one-shot full charge for days when you need maximum battery (e.g. heading out without a charger). The toggle appears in auto mode whenever a power adapter is connected and the battery is not already full. While active, the effective charge ceiling is 100%; the configured bounds are never modified, and the upper-bound dragger is hidden from the slider (the range highlight extends to 100% instead) since it has no effect until the charge completes. When the battery is full, the toggle clears itself, the dragger returns, and normal auto management resumes with your original bounds.

"Full" means the displayed percentage reaching 100% **or** the battery's own fully-charged signal, whichever comes first. Worn batteries can terminate their charge below a displayed 100%; the BMS signal completes the one-shot there instead of holding the charge state open forever.

The one-shot is tied to the current AC session:

- **Reaching full** clears it; charging is inhibited and the battery holds at full while plugged in (no top-up micro-charges).
- **Unplugging** cancels it. At or above the lower bound, a later reconnect parks at the current level as usual. Below the lower bound, the intent downgrades to **Charge to Upper Bound**, so a reconnect behaves exactly like the normal below-lower recovery.
- **Toggling it off** mid-charge re-inhibits immediately; the next cycle restores the default behavior for the current level.
- **Activating it turns Discharge to Upper Bound off** (the setting itself, not just temporarily): draining the battery right after an explicitly requested full charge is never desirable. Re-enable discharge manually if you still want it afterwards.

Like Charge to Upper Bound, the toggle is persisted: an in-progress full charge resumes across an app restart or crash.

#### Sleep and Mid-Charge Protection

The upper bound is enforced in software: a poll must observe the crossing and write the charging-inhibit key. While the Mac sleeps no polls run, but the SMC keeps charging whenever CHTE allows it — so a charge left running at sleep time would sail past the upper bound (seen in the field as "closed the lid charging to 50%, came back to 65%"). Two mechanisms close the gap:

- **Pre-sleep pause (at or above the lower bound).** macOS announces sleep to apps a few seconds before it happens. If a charge is running there, Ampere writes the inhibit inside that grace window and lets the Mac sleep; in-memory state is deliberately untouched, and the wake handler re-asserts "allow" for unpaused states, so the charge resumes on wake and finishes at the upper bound. The announcement cannot be refused, only reacted to — which is why the below-lower case needs the second mechanism.

- **Sleep hold (below the lower bound).** A charge that starts below the lower bound keeps the Mac awake until the upper bound is reached (`pmset -a sleep 0 disablesleep 1` via the helper — the same override discharge uses, minus the display-sleep part, so the screen still sleeps). Pausing such a charge at sleep would strand the battery below the range all night; charging through sleep would overshoot; holding the Mac awake is the only outcome that ends inside the range. A lid close during the hold is simply absorbed — the sleep never initiates. Once the battery climbs past the lower bound, the hold persists only while the lid stays closed (the evidence that a sleep was absorbed); with the lid open it releases, and the pre-sleep pause covers any later sleep attempt. While active it shows the same orange "sleep is disabled" warning as discharge. It is released by reaching the upper bound, unplugging, disabling auto charge, quitting — or, after a crash, by the watchdog through the persistent pmset markers. The hold intent is persisted, so a restart mid-charge (including an in-app upgrade with the lid closed) re-arms it. The hold shares the system-wide `SleepDisabled` bit with other keep-awake tools (e.g. Lidless), so two protections keep them from trampling each other: the bit's pre-hold value is captured and put back on release — finishing a charge must not cancel the other tool's hold and sleep a lid-closed Mac out from under it — and while the hold is engaged the bit is re-checked every poll and re-applied if the other tool's auto-off timer, quit, or crash watchdog cleared it. A captured "1" is honored only if the bit still reads 1 when the hold releases: a holder that released mid-hold gets sleep restored, never a Mac stuck unable to sleep.

- **Charge to Full is exempt.** Its ceiling is 100%, so a sleeping Mac cannot overshoot it, and charging through the night is the point of the feature.

Residual gaps, by design: plugging in a Mac that is *already asleep* charges it with no app awake to manage the bounds; a crash mid-hold restores system defaults (charging allowed, sleep restored); a keep-awake tool that raises the shared `SleepDisabled` bit *while* a hold or discharge is already engaged is indistinguishable from our own override (the bit has no owner), so the release still restores the captured pre-override value; and only the charge hold re-verifies the bit — an external clear during an active *discharge* can still sleep a lid-closed Mac (the wake handler re-asserts the discharge state on wake). All are corrected the next time the app runs a poll — at wake or relaunch — where the standard above-upper handling (inhibit, plus discharge-to-upper if enabled) takes over.

### Manual Charge Control

When auto charge is off and a power adapter is connected, a manual **Pause Charging** / **Resume Charging** button is available.

### Keep Awake

The **Keep Awake** row on the panel stops the Mac from going to idle sleep while a power adapter is connected, for a chosen duration (15 minutes to 8 hours, or Forever). While a timed session runs, the row shows its end time ("until 3:45 PM"). It holds a standard macOS power assertion, the same mechanism `caffeinate` uses, so it needs no admin rights and cannot outlive the app: quitting releases it, and the kernel drops it automatically after a crash. The display still sleeps normally.

On battery the assertion is released and the Mac sleeps as usual; the toggle keeps its intent, so plugging back in re-engages it. The duration is a wall-clock deadline ("until 3:45 PM"), not a stopwatch: it keeps counting on battery, survives an app restart mid-session, and when it passes the toggle turns itself off. Changing the duration during a session restarts the countdown from now.

Unlike the charge sleep hold and the discharge override (which use the system-wide `pmset` override precisely because they must survive a lid close), Keep Awake never blocks lid-close sleep on an undocked Mac. In clamshell mode (external display + power) a closed lid does not sleep the Mac anyway.

### Behavior on Sleep/Wake and Quit/Restart

| Scenario | Sleep → Wake | Quit → Restart |
|---|---|---|
| **Charge to Upper Bound** is ON (charging in progress between bounds) | **The charge pauses just before sleep and resumes on wake.** The sleep announcement handler writes CHTE=inhibit (in-memory state untouched); on wake the handler re-asserts CHTE per the current state — "allow" here, since the state still says an unpaused charge is running — and the charge finishes at the upper bound. A charge that began *below the lower bound* doesn't sleep at all: the sleep hold keeps the Mac awake until the upper bound (see Sleep and Mid-Charge Protection). Toggle stays ON until the upper bound is reached. | **Charging resumes automatically.** The "Charge to Upper Bound" toggle is persisted across restart so an in-progress charge resumes rather than parking at the current level. On launch the app sees `chargeToUpperBound = true` and leaves CHTE in the "allow" state; charging continues until the upper bound is reached, at which point the toggle clears itself. |
| **Charge to Full** is ON (one-shot full charge in progress) | Charging continues through sleep — the ceiling is 100%, so there is nothing to overshoot, and the pre-sleep pause deliberately skips this state. The wake handler re-runs the state machine, which keeps CHTE in "allow" until the battery is full. Toggle stays ON until full. | **Charging resumes automatically.** The toggle is persisted; on launch the app skips the between-bounds inhibit and leaves CHTE in "allow", so the full charge continues (even past the configured upper bound) until full, where the toggle clears itself. A launch that finds the flag set but the Mac on battery clears it, because the one-shot is tied to the AC session it was started in. |
| **Discharge to Upper Bound** is ON (discharging above upper bound) | Discharging continues. System sleep is prevented during discharge, so normal sleep should not occur. If forced (e.g. lid close), the wake handler re-asserts the discharge SMC state. Toggle stays ON. | **Discharging resumes automatically.** The "Discharge to Upper Bound" toggle is persisted. On restart, the app clears stale SMC state, then the first refresh cycle detects the battery is still above the upper bound and restarts discharge. Toggle stays ON. |

On firmware without CHTE all three rows collapse into one behavior: the macOS charge limit holds the target on its own through sleep and across a restart, and the first poll after a relaunch simply hands it the current target again. See Firmware without CHTE below.

### Settings and Safety

- **Settings persist across restarts** - auto charge, discharge toggle, charge bounds (an unregistered copy always relaunches with the default 40 to 60%), and keep awake (including a mid-session deadline) are saved and restored when the app relaunches.
- **Quitting the app restores system defaults** - all SMC overrides (charging inhibit, discharge) and power management changes (sleep settings) are cleared when the app exits, and on firmware without CHTE the macOS charge limit is put back to whatever it was before. Your Mac returns to its normal charging and sleep behavior. If the app crashes or is force-killed, a watchdog daemon cleans up automatically within a few seconds.

### Health Check

The app periodically verifies that the actual SMC key values (`CHTE` and `CHIE`) match the expected state. A `CHTE` mismatch is repaired, not just reported: firmware or a USB-C PD renegotiation can silently reset the key (observed across sleep/wake), and the state machine is edge-triggered — it never re-issues a write for a state it believes is already in force, so a drifted key would otherwise stay drifted until the next sleep/wake while the battery charges past the bound (or refuses to finish a charge). The health check re-writes the expected value and re-verifies on the next cycle. The first repair attempt is silent; only a mismatch that survives a repair shows the warning in the popover and turns the menu bar battery icon orange — at that point the helper itself is suspect, and the warning's advice (revoke & re-grant admin) is appropriate. `CHIE` mismatches are reported but never auto-repaired: starting or stopping a discharge belongs to the state machine, with its sleep override and watchdog attached.

Health checks only run while a power adapter is connected — on battery the app is not managing charging, so there is no expected SMC state to verify. Until the first check of a session has run, the About panel shows the check as **waiting for power adapter** (on battery) or **pending** (plugged in, during the warm-up below).

On firmware without CHTE (see Firmware without CHTE below) the check compares the target powerd is enforcing (`pmset -g battlimit`) with the one the app last handed to the macOS charge limit, plus `CHIE`, which must be clear since nothing writes it in that mode. The agent applies a new target at its next once-a-minute evaluation (82 seconds observed on macOS 27.0), so a mismatch inside a 150-second settle window after a write is not reported; past it the target is re-issued, silently the first time, and only a mismatch that survives that shows the warning. The About panel names the mechanism in force.

#### Polling and Health Check Timing

The app polls battery state on a timer. Power-source changes (plug/unplug, charge-level ticks) also trigger an immediate poll via an IOKit notification, so adapter transitions are handled within about a second rather than at the next interval — a short unplug between polls still cancels Charge to Full and stops an active discharge. Health checks run every poll cycle after an initial 3-cycle warm-up (to let launch cleanup settle), whenever a power adapter is connected.

|  | Popover closed (slow) | Popover open (fast) |
|---|---|---|
| **First poll** | Immediately on launch | Immediately on open |
| **Poll interval** | 60s | 10s |
| **First health check** | Cycle 4 — 3 min after launch | Cycle 4 — ~30s after open* |
| **Health check interval** | Every cycle — 60s | Every cycle — 10s |

\* The cycle counter is global and does not reset when switching between fast and slow polling. If the app has already been running, the first health check after opening the popover depends on the current cycle count.

Health checks also run immediately after revoking admin access, and after re-granting it from inside the app (when enabling a charge-control feature reinstalls the helper), so the warning clears (or appears) without waiting for the next scheduled check. After an app relaunch — including the revoke → relaunch → re-grant flow — the first check follows the normal warm-up schedule above.

#### Diagnostics

Every line the app, the helper, and the watchdog log goes to the unified log under the subsystem `com.az-code-lab.ampere` (categories `app` and `helper`), with the message marked public:

```
log show --last 1h --predicate 'subsystem == "com.az-code-lab.ampere"'
```

NSLog is not used anymore: from macOS 27 its messages show up in `log show` only as `<private>`, which made the app's own diagnostics unreadable exactly when they were needed. The watchdog logs one line when a restore starts failing and one when it succeeds, so a crash whose cleanup never completes is visible there too.

### Updates

The app checks the Homebrew cask for a newer version 5 minutes after launch and about once a day after that. When one is found, the menu bar battery icon gains a small blue badge dot (hover for the version; the dot renders alongside the orange health-warning tint when both apply) and the panel footer shows an **Update to X** button. Clicking it:

1. Downloads the release DMG from GitHub Releases (progress shown in the footer, with a cancel button).
2. Verifies the download: SHA-256 must match the cask, the code signature must be intact, and the Team ID must match the running app.
3. Swaps the new bundle into place (one atomic exchange; volumes without swap support fall back to two renames) and relaunches.

The relaunch takes the normal quit → restart path: SMC overrides are restored on the way down, and persisted state (auto charge, bounds, an in-progress charge/discharge to upper bound) resumes in the new copy. If the bundled SMCWriter changed, the next launch asks for your admin password once to install the new helper — same as after a Homebrew upgrade.

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

`run.sh` and `release.sh` pass the linker the SDK explicitly (`SDK_FLAGS` in both scripts). Under Xcode 27's toolchain a bare `swift build` produces a binary stamped as built against the macOS 14 SDK: SwiftPM's Swift Build engine runs `swiftc` without `SDKROOT`, and `clang` then records the deployment target instead of the SDK version. AppKit and SwiftUI run such a binary in macOS 14 compatibility mode on every later macOS; on macOS 27 that showed an empty "Ampere Settings" window at launch. Check a build with `otool -l .build/debug/Ampere | grep -A4 LC_BUILD_VERSION`; the `sdk` line must show the current SDK, not `14.0`.

## Uninstall

Delete `Ampere.app` from Applications, or:

```bash
brew uninstall ampere
```

Quit Ampere first if it is running (Finder refuses to trash a running app; Homebrew quits it). Quitting restores charging and sleep settings. Two minutes after the bundle is gone, the cleanup job removes everything else, so the Mac ends up as if Ampere had never been installed:

- `/Library/PrivilegedHelperTools/az-ampere-smc` - the SMCWriter helper binary (runs as root to write SMC keys)
- `/etc/sudoers.d/az-ampere` - the sudoers rule that allows passwordless execution of the helper
- `/Library/Application Support/az-ampere/` - state directory for the saved-sleep markers (only exists if discharge or the mid-charge sleep hold was ever used)
- `/Library/LaunchDaemons/com.az-code-lab.ampere.cleanup.plist` - the cleanup job itself
- `~/Library/Preferences/com.az-code-lab.ampere.plist`, `~/Library/Caches/com.az-code-lab.ampere`, `~/Library/HTTPStorages/com.az-code-lab.ampere`, and `~/Library/Saved Application State/com.az-code-lab.ampere.savedState` - preferences (including the registration), the update check's cache, and window state, for every account on the Mac

The job exists once the app has run from that location with admin access granted, and only runs while it is allowed under System Settings > General > Login Items & Extensions. If a restore fails, it keeps everything in place for the watchdog to retry and tries again at the next boot. There is no `zap` stanza; `brew uninstall ampere` alone is the complete removal. Two things stay: the copy of `Ampere.app` in the Trash until you empty it, and the Open at Login entry if you had enabled it, which macOS manages. Switch launch at login off in Settings before uninstalling, or remove the entry under Login Items & Extensions.

### Remove everything now

Quit Ampere first. The helper restores charging and sleep settings, then removes every file above and unloads the job; nothing is removed if the restore fails.

```bash
sudo /Library/PrivilegedHelperTools/az-ampere-smc purge
```

### Keep the app, drop the admin access

Click **Settings** in the panel footer, then **Revoke** on the Admin Access row. This restores charging and sleep settings, then removes your account's sudoers line and, once no other account is authorized, the helper binary, the state directory, and the cleanup job (one administrator prompt). Preferences stay, since the app does. If restoration fails, the files and recovery watchdog remain available and the app reports the failure. `sudo /Library/PrivilegedHelperTools/az-ampere-smc uninstall` does the same for every account at once and also keeps preferences.

## Troubleshooting

**"Pause Charging" does nothing / no password prompt appears**

The helper binary may be corrupted. Fix by revoking and re-granting access:

1. Click **Settings** in the panel footer, then **Revoke** on the Admin Access row
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

While **Charge to Full** is active, this table applies with the upper bound read as 100 and CHTE expected to be `0x00 00 00 00` (allow) everywhere below it. (Discharge is always off in that state — activating the one-shot disables it.) For any 100% target, the battery's `FullyCharged` flag counts as "at the bound", covering worn batteries that terminate below a displayed 100%.

#### Auto Mode — Discharge to Upper Bound ON

| Charge level | Expected CHTE | Expected CHIE |
|---|---|---|
| > upper bound | `0x01 00 00 00` | `0x08` |
| >= lower bound and <= upper bound | `0x00 00 00 00` or `0x01 00 00 00` | `0x00` |
| < lower bound | `0x00 00 00 00` | `0x00` |

Both keys are written via IOKit's `IOConnectCallStructMethod` (selector 2) to the `AppleSMCKeysEndpoint` service (falling back to `AppleSMC`). Writing requires root privileges. Reading does not require root.

### Firmware without CHTE (macOS 27)

The firmware that ships with macOS 27, and with the macOS 26.7 update, no longer has a `CHTE` key: the SMC reports it as not found, and every helper write of `inhibit` or `allow` fails. Apple's replacement, a firmware charge-limit interface (`bfD0`/`bfE0`/`bfF0`), exists in the key table but refuses every call from a process without the private `com.apple.private.iokit.soc-limit` entitlement, root included. `CHIE` still works. Without the inhibit key the previous design could not hold a level at all: a discharge that reached the upper bound resumed charging at full current within seconds, and the health check never ran because its first read failed.

On such firmware the app takes a different path, decided when it takes charge control (`readKey(CHTE)` fails): it holds the battery through macOS's own **Manual Charge Limit**, the feature behind System Settings > Battery > Charge Limit. PowerUIAgent (root) keeps that feature's switch and target in its preference domain, `com.apple.smartcharging.topoffprotection` under `/var/root/Library/Preferences`, as `MCLFeatureState` (1 = on) and `mclLimitValue` (percent). The agent registers the target with powerd and the firmware enforces it: charging stops at the target, including during sleep and across a reboot, and a battery above the target is drained down to it by the firmware itself (at about 2 A; the firmware decides when to begin, observed anywhere from one to eight minutes after the target was set). The agent's own request interface refuses targets below the range its slider offers, so the helper writes the two keys directly (`native-limit:<percent>`, valid 1 to 100) and posts the Darwin notification `com.apple.smartcharging.defaultschanged`, which the agent reloads its settings on. The agent applies a new target at its next once-a-minute evaluation (56 and 82 seconds observed). Nothing is written to `CHTE` or `CHIE` in this mode, and no `pmset` override is needed, because the firmware, not a poll, does the enforcing.

The app maps its existing state machine onto one number. The machine still decides the intents exactly as before (rules 1 to 3, the charge-to-full session, the unplug edge); what changes is what each outcome writes:

| State machine outcome | Target handed to macOS |
|---|---|
| Charge to Full | 100 |
| Charge to Upper Bound (explicit, or rule 1 below the lower bound) | the upper bound |
| Above the upper bound with Discharge to Upper Bound on | the upper bound (the firmware drains to it) |
| Any other paused state (between bounds, at the bound, above it with discharge off) | the current level (a hold) |
| Manual mode, paused on AC | the current level |
| Manual mode, resumed | released: the user's own setting is back |

A hold is sticky: its level is fixed when the hold begins and kept while the firmware settles, so a percentage that ticks up in the minute before the target applies is drained back rather than chased. Off AC the intent is written ahead of the next plug-in: an armed charge starts the moment the adapter connects, and a hold follows the falling level down so a reconnect never charges toward a stale level. Reaching a bound turns the charge target into a hold at the same number without another write. Because the agent needs up to a minute to act, a level can overshoot a fresh hold by a percent or two before it settles; the firmware then drains it back. Sleep holds and the pre-sleep pause do not arm in this mode, and the wake handler re-asserts nothing.

Before the first override the helper saves the agent's original switch and target to `/Library/Application Support/az-ampere/saved-native-limit` (`"<state> <limit>"`, `-` for an absent key). Every restore path, `restore` at quit, the launch cleanup, the crash watchdog, `uninstall`, and the cleanup job, runs `native-limit-release`: it asks the agent to switch the feature off through its own client interface (the private PowerUI framework, resolved at runtime), which is the only path on which the agent clears the limit it registered with powerd; a preference write turning the feature off leaves that registration in place. If the user had a limit of their own, it is switched back on with their value. The marker is consumed only after every step succeeds, so a later restore can retry with the same originals. `nodischarge` does not release the limit; it only ends a discharge. A change the user makes in System Settings while the app is managing is overwritten by the app's next target, and the pre-session value is what gets restored.

The restore paths also treat a missing `CHTE` as nothing to restore. Without that, `restore` failed at the `allow` write on this firmware and the watchdog it was meant to retire retried every two seconds for as long as the Mac stayed up.

Everything above is bypassed while `CHTE` exists: on earlier firmware the helper, the state machine, the sleep handling, and the health check run exactly as they always did.

#### Other macOS 27 changes

macOS 27 reorganized the battery's registry data. The `AppleSmartBattery` entry lost its top-level `DesignCapacity`, `AppleRawMaxCapacity`, `AppleRawCurrentCapacity`, and `Temperature` keys, and its `BatteryData` dictionary shrank to eleven keys. The detailed `BatteryData`, under the same key names as before and including `LifetimeData`, now sits on a child entry of class `AppleSmartBatteryPack`. (`ioreg -a` silently omits that dictionary, because it holds a value a property list cannot carry, which makes the data look deleted; `ioreg -l` shows it.)

The reduced `BatteryData` that stayed on the battery entry carries the same capacities as `DesignCapacity`, `FullChargeCapacity`, and `RemainingCapacity` (equal to the pack's raw values when compared), and the SMC's `TB0T` sensor tracks the gauge temperature to 0.1°C, so Health, Raw Charge, and Temperature read those when the top-level keys are absent. Battery Served is computed from the gas gauge's operating-hours counter, `LifetimeData.TotalOperatingTime`: the gauge runs off the cells and has counted since the pack was built, so the counter is the battery's age. The app looks for `LifetimeData` on the battery entry first and then on its `AppleSmartBatteryPack` child. On a 2021 MacBook Pro the counter reads 44,063 hours, which dates the pack within two weeks of the manufacture week encoded in the battery's serial number.

A panel dragged off the menu bar item becomes a floating window, which AppKit makes movable by its background. On macOS 27 SwiftUI content no longer counts as background for that purpose: a mouse-down anywhere the hosting view draws (the panel's background fill, text, the cards) does not start a window drag, and the panel is SwiftUI edge to edge, so a torn-off panel could not be moved at all. The panel now carries a SwiftUI `WindowDragGesture`, which moves the window by any spot that is not a button, a switch, or a slider dragger (those sit deeper in the view hierarchy and keep precedence). The gesture is live only while the panel is detached: on the attached popover it would move the popover without tearing it off, and the tear-off there belongs to AppKit's own recognizer.

The helper binary (`SMCWriter`) is a minimal executable with no AppKit/SwiftUI dependencies. Its installation at `/Library/PrivilegedHelperTools/az-ampere-smc` is root-owned, and the complete path must prevent writes or replacement by ordinary users. The watchdog always starts from this checked installation path.

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

**`pmset -a sleep 0 disablesleep 1 displaysleep 0`** before the CHIE write. This disables all system sleep at the OS level, preventing macOS from sleeping during the PD disruption.

Because the `-a` override stamps **all** power profiles, the original `sleep` and `displaysleep` values are captured per profile (Battery and AC, from `pmset -g custom`) before the override, and restored per profile (`pmset -b` / `pmset -c`) when discharge stops — a user with different battery-vs-AC sleep settings gets both back exactly. If the originals cannot be captured (pmset unreadable, marker unwritable), the discharge refuses to start rather than override sleep with no way to restore it.

The pre-override value of the `SleepDisabled` bit itself is captured the same way (into `saved-sleep-disabled`), because the bit is global and shared with other keep-awake tools: restoring it blindly to 0 — what builds before this marker did — cancels e.g. Lidless's hold and puts a lid-closed Mac to sleep out from under it. A saved "1" is honored only if the bit still reads 1 at restore time; a holder that released mid-override (auto-off timer, quit) must not be "restored" into a Mac that can never sleep. On re-entry (a hold re-assert, or a re-arm after restart) an existing marker is kept, except that a saved "1" is corrected to "0" when the bit reads 0 — evidence the external holder is gone.

The saved values live in `/Library/Application Support/az-ampere/saved-sleep` (plus `saved-sleep-display` and `saved-sleep-disabled`). The markers deliberately live outside `/tmp`: macOS wipes `/tmp` at boot while `pmset -a` overrides persist across reboots, so a crash + reboot during discharge would otherwise lose the saved values and leave sleep permanently disabled. With the persistent markers, the next launch's cleanup finds them and restores the original settings. (Single-value markers written by older builds — including to the legacy `/tmp` location — are still honored; their one value is applied to both profiles, matching what those builds' `-a` restore did.)

The mid-charge **sleep hold** (see Sleep and Mid-Charge Protection) saves and restores through the same markers via the `hold-sleep` / `release-sleep-hold` helper commands, so every existing restore path — `nodischarge`, the watchdog, launch cleanup — undoes it too. The hold's override is `sleep 0 disablesleep 1` only (no `displaysleep 0`: there is no CHIE write and no PD renegotiation to protect against, so the display may sleep while the machine charges). All three markers are still saved, because the shared restore always puts back all of them.

### Watchdog Daemon

A **watchdog daemon** is always running while the app is active. It is spawned via `posix_spawn` on launch, re-spawned after discharge stops, and also spawned by the discharge command. The daemon:

1. Runs as a detached root process (independent of the app and sudo process chain).
2. Polls the app's PID every 2 seconds.
3. If the app dies (crash, `kill -9`, Ctrl+C, etc.), the watchdog cleans up within seconds:
   - Clears `CHTE = 0x00` (allows charging)
   - Clears `CHIE = 0x00` (stops discharge)
   - Restores sleep settings via `pmset` — only if the save-sleep marker file exists (i.e. discharge or the mid-charge sleep hold had overridden pmset); otherwise leaves the user's sleep settings untouched
   - Puts the macOS charge limit back to the saved original — only if the `saved-native-limit` marker exists (firmware without CHTE)
   - Exits after successful recovery; if an SMC or pmset operation fails, retries on the next poll and retains any sleep settings still needing restoration

The watchdog must be spawned with `posix_spawn` (not `fork`) because the Swift/ObjC runtime is not fork-safe — forked children crash when using Foundation, IOKit, or Objective-C APIs. Similarly, signal handlers (`SIGTERM`/`SIGHUP`) cannot be used for cleanup because they can only call async-signal-safe C functions, not Swift/Foundation/IOKit APIs. It is spawned with `POSIX_SPAWN_SETSID` so it runs in its own session: without that it would share the app's foreground process group, and a terminal Ctrl+C (dev runs via `run.sh`) would SIGINT the watchdog at the same instant as the app it exists to clean up after.

On app launch, CHIE and saved sleep settings are restored before existing watchdogs are retired. CHTE is set to inhibit when auto charge is enabled, the battery is at or above the lower bound (or the BMS reports a full battery for a 100% target), and no valid charge-to-upper or charge-to-full session is being resumed; otherwise CHTE is cleared. A fresh watchdog is then spawned. Normal quit uses a single `restore` command that restores both SMC keys and sleep before retiring the watchdog. If cleanup fails, the watchdog remains alive to retry after the app exits.

### Cleanup Job

Nothing runs when `Ampere.app` is dragged to the Trash, and Homebrew's `uninstall` stanza runs during `brew upgrade` as well, so removing the helper there would cost an administrator prompt on every upgrade and removing preferences there would wipe the settings on every upgrade. That is also why the cask has no `zap` stanza. Instead the app registers a root launchd job, `/Library/LaunchDaemons/com.az-code-lab.ampere.cleanup.plist`, that runs the installed helper with `uninstall-if-missing:<bundle path>` at boot (`RunAtLoad`) and whenever the bundle path changes (`WatchPaths`). `AssociatedBundleIdentifiers` lists the job under Ampere in System Settings > General > Login Items & Extensions.

Registration is the `register-daemon:<path>` helper command, run over the account's passwordless rule after the launch cleanup and after a re-grant from the UI, whenever the installed plist does not match the running copy's path. Root accepts only a real copy of the app (`Contents/Info.plist` must carry Ampere's bundle identifier), so an account with helper access cannot make root watch other paths. The app skips registration for a bare debug executable and for a quarantined copy running from macOS's randomized App Translocation mount, whose path would vanish at every quit.

When the job runs it sleeps two minutes, then uninstalls only if the bundle is still missing, its parent directory exists (an unmounted volume proves nothing), and no process named Ampere is running (a running copy was moved, not removed; it re-registers on relaunch). The grace period is what keeps `brew upgrade`, `brew reinstall`, and the in-app updater from triggering it: all three remove and re-create the bundle within seconds.

The helper's `uninstall` command, used by Revoke once no account remains, runs `restore` first and stops there if it fails (exit 2), keeping the helper, the saved settings, and the watchdog. Otherwise it removes the sudoers file, the helper, the pre-0.0.60 helper, the state directory, and the job's plist, then unloads the job. `purge`, which the job runs and which is the manual complete removal, additionally removes each local account's preferences, caches, HTTP storage, and saved window state (accounts from uid 500 up, as the directory service lists them); Revoke never does, because the app stays installed. For a logged-in account the preferences are cleared through that user's `cfprefsd` first (`launchctl asuser <uid> sudo -n -u <user> defaults delete com.az-code-lab.ampere`), then the file is unlinked. Deleting the plist alone would not work: the running `cfprefsd` keeps the domain in memory and rewrites the file, so a reinstall would read the old registration back. Accounts that are not logged in have no `cfprefsd` to reach, so the direct unlink is enough. Run as the job, the helper hands the unload to a detached shell and exits first, since unloading a job terminates its process.

### Process Architecture

The app cannot write to the SMC directly — it requires root privileges. Instead, it spawns short-lived root processes (`sudo SMCWriter`) for each SMC operation, plus a long-lived watchdog daemon as a safety net that cleans up if the app dies unexpectedly, and a launchd job that uninstalls the helper once the app itself is gone.

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
  |     |-- SMC write CHIE = 0x00            disable active discharge
  |     |-- pmset restore sleep settings     only if save-sleep file exists
  |     |-- pkill watchdog                   only after successful restore
  |     \-- exit(0)                          failure returns nonzero
  |
  |-- sudo SMCWriter restore                 (quit / revoke / migration)
  |     |-- SMC write CHIE = 0x00            disable active discharge
  |     |-- SMC write CHTE = 0x00            allow charging
  |     |-- pmset restore sleep settings     only after CHIE clears
  |     |-- pkill watchdog                   only after all restores succeed
  |     \-- exit(0)                          failure preserves recovery
  |
  |-- sudo SMCWriter hold-sleep              (one-shot, root)
  |     |-- save pmset markers               same markers as discharge
  |     |-- pmset -a sleep 0 disablesleep 1  keep Mac awake mid-charge
  |     \-- exit(0)                          (displaysleep untouched)
  |
  |-- sudo SMCWriter release-sleep-hold      (one-shot, root)
  |     |-- pmset restore sleep settings     only if save-sleep file exists
  |     \-- exit(0)
  |
  |-- sudo SMCWriter spawn-watchdog:<pid>    (one-shot, root)
  |     |-- posix_spawn SMCWriter watchdog   spawn safety net daemon
  |     \-- exit(0)
  |
  |-- sudo SMCWriter register-daemon:<app>   (one-shot, root)
  |     |-- write LaunchDaemons plist        watch the installed bundle
  |     |-- launchctl bootstrap              load the cleanup job
  |     \-- exit(0)
  |
  |-- sudo SMCWriter uninstall | purge       (revoke / manual)
  |     |-- restore                          as above; failure removes nothing
  |     |-- rm sudoers, helper, state dir    and the cleanup job's plist
  |     |-- purge: clear each account's      prefs via cfprefsd (logged-in),
  |     |     then rm prefs, caches,          HTTP storage, saved state
  |     |-- launchctl bootout                unload the cleanup job
  |     \-- exit(0)
  |
  \-- SMCWriter watchdog:<app-pid>           (daemon, root, detached)
        |-- sleep(2) loop                    poll every 2 seconds
        |-- if app PID gone:
        |     |-- SMC write CHIE = 0x00      stop discharge
        |     |-- SMC write CHTE = 0x00      allow charging
        |     |-- pmset restore sleep        only if save-sleep file exists
        |     \-- exit(0)                    retry on failure
        \-- (runs until app dies)

launchd (root)
  \-- SMCWriter uninstall-if-missing:<app>   (cleanup job: at boot, on bundle change)
        |-- sleep(120)                       grace period for upgrades
        |-- if bundle gone, parent present,  a running copy was only moved
        |   and no Ampere process running:
        |     \-- purge                      as above
        \-- exit(0)
```

## License

MIT
