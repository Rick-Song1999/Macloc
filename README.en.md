# macloc — System-wide simulated location on macOS

Set the **system-wide** location of an Apple Silicon Mac to any latitude/longitude.

It changes `locationd`'s own simulated provider, so every program holding Location Services permission — Maps, Safari, WeChat, ride-hailing apps — reads the coordinates you picked instead of the real ones.

**中文 | [README.md](README.md)** · [MIT License](LICENSE)

```
./install.sh 39.9042 116.4074    # install (Beijing)
./install-daemon.sh              # install the password-less daemon
./build-ui.sh                    # build the menu bar app
open /Applications/MacLocBar.app # pick a city, effective in 3–6 s, no password prompt
```

---

## Table of contents

- [What it does](#what-it-does)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Daemon protocol](#daemon-protocol)
- [Verifying](#verifying)
- [Known limits](#known-limits)
- [Uninstalling](#uninstalling)
- [What it changes on your system](#what-it-changes-on-your-system)
- [Security design](#security-design)
- [File map](#file-map)
- [License](#license)

---

## What it does

| | Current location | After the change |
|---|---|---|
| Blue dot in Apple Maps | your actual position | the coordinates you set |
| Safari / WeChat / ride-hailing apps | your actual position | the coordinates you set |
| Reported accuracy | real | fixed `hAcc = 5 m` |
| Time to take effect | — | ≈ 2 s (≈ 5 s on a cold daemon start) |

One change moves **every** CoreLocation client at once — no per-app handling.

---

## Prerequisites

### At a glance, per channel

| | **A · prefs** | **B · daemon** | **C · XPC** |
|---|---|---|---|
| Scripts | `install.sh` / `set.sh` / `stop.sh` | `install-daemon.sh` / `loc.sh` | `xpc-push.sh` |
| Admin password | prompted every time | prompted once, at install | not needed |
| **SIP must be disabled** | **no** | **no** | **yes, and a reboot is required** |
| Logged-in graphical session | required | required | not needed |
| Xcode CLT | not needed | required | required |
| Restarts `locationd` | yes | yes | no |
| Time to change coordinates | ≈ 2 s | ≈ 2 s | instant |
| Graphical UI | none | yes (`MacLocBar.app`) | none |

### Hard requirements

**1 · Apple Silicon (arm64)**

`install.sh` checks `uname -m` first and exits on anything else.
(`arm64e` counts — it is an arm64 variant.)

**2 · A logged-in graphical session**

- The admin prompt goes through `osascript ... with administrator privileges`, which needs a GUI
  session to display it. **Running `install.sh` over plain SSH will fail or hang.**
- The daemon only accepts connections from the **console user** or root (it verifies the peer uid
  with `getpeereid`). Any other user gets `ERR PERMISSION`.

**3 · The admin password**

One system authorization prompt at install time, then you type it once.
No passwordless sudo is required and `sudoers` is never modified — every privileged step goes through
the native macOS authorization dialog.

**4 · Xcode Command Line Tools**

Only these scripts compile anything:

| Script | What it compiles |
|---|---|
| `install-daemon.sh` | `maclocd` (Swift) |
| `build-ui.sh` | `MacLocBar.app` (Swift) |
| `build-icon.sh` | the icon generator |
| `verify.sh` | `finddot` (blue-dot finder for screenshots) |
| `xpc-push.sh` | the injected dylib (arm64e) |

```bash
xcode-select --install
```

Channel A alone (`install.sh` / `set.sh` / `stop.sh`) does **not** need this.

**5 · Tools that ship with macOS**

`/usr/libexec/PlistBuddy` · `/usr/bin/codesign` · `/bin/launchctl` · `/usr/bin/nc` · `/usr/sbin/screencapture`

**6 · The Location Services master switch**

`install.sh` turns it on for you (it writes `LocationServicesEnabled = true`).
But while the master switch is **off**, simulated fixes are still produced and every client only gets
`kCLErrorDomain error 1` (LocationUnknown) — the blue dot will not move.

**7 · The target app's own Location permission (TCC)**

The app you use to check the result must hold its own "System Settings → Privacy & Security →
Location Services" permission, otherwise it reads nothing. System components (the Wi-Fi stack,
CountryTracker, Find My) are not subject to this.

### Do I have to disable SIP?

**Channels A and B: no.** Both only edit `locationd`'s own preferences — nothing is injected and no
third-party binary is loaded.

**Channel C: yes, and you must reboot.**

```bash
sudo csrutil disable --no-internal
# reboot
```

Reason: channel C injects a dylib into
`/System/Library/CoreServices/CoreLocationAgent.app`, an **arm64e platform binary**. With SIP
enabled, dyld refuses the injection outright.

### Optional extras

| Feature | Additionally needs |
|---|---|
| `verify.sh` | Apple Maps (built in) + "Screen Recording" for your terminal |
| `tools/uitest.sh` | "Accessibility" for your terminal |
| `tools/loctest-app.sh grant` | `sqlite3` + "Full Disk Access" for your terminal (it edits `TCC.db`) |

### One-shot self check

```bash
./preflight.sh
```

```
[ OK ] Architecture           Apple Silicon (arm64) ✅
[ OK ] Graphical session      console user = <you> ✅ (required for the admin prompt)
[ OK ] Admin prompt           osascript available (one system authorization prompt at install) ✅
[ OK ] swiftc                 .../swiftc ✅ (compiles the daemon and the UI)
[INFO] SIP                    disabled — channels A/B do not need it; channel C does
[ OK ] Location Services      enabled ✅ (clients can read a position)
```

A `FAIL` exits with status 1; `WARN` only warns and does not block.

---

## Install

```bash
git clone https://github.com/Rick-Song1999/Macloc.git
cd Macloc
```

### Channel A · preferences (smallest useful setup)

```bash
./install.sh 39.9042 116.4074     # latitude longitude (Beijing)
```

One admin prompt, effective immediately. The script does four things: check the environment → open the
Location Services master switch → write the simulated coordinates → restart `locationd` and read the
values back to verify.

### Channel B · daemon + graphical UI (recommended)

```bash
./install-daemon.sh    # root daemon — changing coordinates no longer needs a password
./build-ui.sh          # build MacLocBar.app and install it into /Applications
open /Applications/MacLocBar.app
```

`build-ui.sh` tries a passwordless install first (`/Applications` is `775 root:admin`, so being in
the `admin` group is enough); it only prompts if the permissions were changed.

### Channel C · XPC, real-time (optional)

```bash
sudo csrutil disable --no-internal && sudo reboot

./xpc-push.sh 22.3193 114.1694     # switch to Hong Kong instantly, no locationd restart
./xpc-push.sh --stop                # stop
```

---

## Usage

### The graphical UI (`MacLocBar.app`)

Opening it shows the main panel, with 26 preset cities — one click switches:

```
┌──────────────────────────────────────────┐
│  [App icon]  MacLoc                      │
│              ● Simulation active         │
│              ⚡ daemon channel (no pwd)   │
│                                          │
│  Current location                        │
│  London                                  │
│  51.49433, -0.08350                       │
│                                          │
│  Quick switch                            │
│  ✓London Beijing Shanghai Tokyo HK Taipei│
│   Singapore Kyoto New York S.F. L.A. …   │
│                                          │
│  Custom coordinates [51.49433] [-0.08350]│
│  [Verify blue dot] [Open Maps] [Turn off]│
│  ✓ Switched  London                      │
└──────────────────────────────────────────┘
```

- A **blue map-pin icon** appears in the right side of the menu bar; clicking it opens a quick menu
  (presets / custom coordinates / verify / turn off / language / quit).
- The UI is **bilingual**. Toggle `中文 │ EN` in the top-right of the main window, or use
  "Language ▸" in the menu bar.
- The first launch follows your system language, then remembers your choice.
- The app is **launch-on-demand** — it does not auto-start at boot. Want the icon at login?
  ```bash
  ./install-login.sh            # install (LaunchAgent com.macloc.bar)
  ./install-login.sh --remove   # remove
  ```
- After you quit the app, **not a single macloc process remains** (the daemon stands down too).

### Command line

| Command | What it does |
|---|---|
| `./loc.sh <lat> <lon>` | Change coordinates; picks the channel automatically (daemon first, auth prompt as fallback) |
| `./set.sh <lat> <lon>` | Change coordinates, always via the authorization prompt |
| `./status.sh` | Show status (daemon channel / coordinates / whether it is active) |
| `./verify.sh` | Verify automatically: open Maps → screenshot → find the blue dot → save a close-up |
| `./stop.sh` | Turn simulation off and restore the original state |
| `./preflight.sh` | Check the prerequisites |

The argument order is **latitude longitude**.

```bash
./loc.sh 35.6762 139.6503     # Tokyo
./loc.sh 51.49433 -0.08350    # London
```

You can also talk to the daemon directly:

```bash
printf 'SET 51.49433 -0.08350\n' | nc -U /var/run/macloc.sock
```

### Preset cities

London · Beijing · Shanghai · Tokyo · Hong Kong · Taipei · Singapore · Kyoto · New York ·
San Francisco · Los Angeles · Seattle · Paris · Berlin · Amsterdam · Rome · Moscow · Dubai ·
Riyadh · Bangkok · Sydney · Melbourne · Auckland · São Paulo · Mexico City

---

## How it works

### Channel A · preferences

`locationd` ships with a **`CLSimulatedLocationProvider`**. At startup it reads four keys from **its
own** preference domain:

```
/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd.<hostUUID>.plist
    AllowSimulatedLocations      = true
    SimulatedLocationLatitude    = <lat>
    SimulatedLocationLongitude   = <lon>
    SimulatedLocationAccuracy    = 5
```

On a hit, `locationd` logs `@ClxProvider, start, simulated` and then produces **one `@ClxSimulated`
fix per second**, at a priority higher than every real provider, and broadcasts it to every registered
CoreLocation client.

The same keys are also written to `/Library/Managed Preferences/com.apple.locationd.plist` (MCX) to
keep the two in sync, and the `LocationServicesEnabled` master switch is maintained there.

> ⚠️ The same keys in the **user** domain (`~/Library/Preferences/com.apple.locationd.plist`) are
> **not read** by `locationd`. They must go into
> `/var/db/locationd/Library/Preferences/ByHost/`.

> ⚠️ **`locationd` must be restarted** after changing coordinates, otherwise the simulated provider
> keeps serving its cached value. The script always does `killall cfprefsd` +
> `killall -u _locationd locationd`, then reads the values back.

### Channel B · daemon

On top of channel A, a root daemon receives coordinate changes over a unix socket.

What gets installed:

| Path | Purpose |
|---|---|
| `/Library/LaunchDaemons/com.macloc.agent.plist` | launchd job (**socket-activated, on demand**) |
| `/usr/local/libexec/macloc/maclocd` | the daemon binary |
| `/var/run/macloc.sock` | unix socket (0666, created by launchd) |
| `/var/db/macloc/state` | authoritative state (`root:wheel 0644`) |
| `/var/db/macloc/backup` | backup of the original preferences (`root:wheel 0700`) |
| `/var/log/maclocd.log` | daemon log |

**On demand**: the plist sets `RunAtLoad=false` + `KeepAlive=false` and adds a `Sockets` dictionary:

```xml
<key>Sockets</key>
<dict>
  <key>com.macloc.sock</key>
  <dict>
    <key>SockPathName</key>  <string>/var/run/macloc.sock</string>
    <key>SockPathMode</key>  <integer>438</integer>   <!-- 0666 -->
    <key>SockFamily</key>    <string>Unix</string>
  </dict>
</dict>
```

So:

| Moment | What exists on the system |
|---|---|
| Idle (app closed) | **not a single macloc process** — only the socket file launchd keeps alive |
| A client connects | launchd spawns `maclocd` (root) |
| After the work is done | the daemon exits by itself after **20 s** idle |
| The app quits | it sends `QUIT`; the daemon stands down cooperatively (it will not cut a request in flight) |

### Channel C · XPC

The private CoreLocation class `CLSimulationManager` talks to the mach service
`com.apple.locationd.simulation`.

That service **verifies the client's signature** and requires the
`com.apple.locationd.simulation` entitlement — on the whole system only
`/System/Library/CoreServices/CoreLocationAgent.app` holds it.

So the dylib is injected into `CoreLocationAgent` and pushes the coordinates with its legitimate
identity. `locationd` then logs `Setting simulation to 1 for all location providers`.

Three hard constraints:

- The dylib **must be built as `arm64e`**. Platform binaries are arm64e; injecting an arm64 dylib is
  rejected by dyld.
- The dylib must be **replaced atomically** (`cp x.new && mv`). Overwriting a still-mapped inode in
  place makes AMFI report `SIGKILL (Code Signature Invalid)` and `CoreLocationAgent` crash-loops.
- Changing coordinates requires **`stopLocationSimulation` + `clearSimulatedLocations` first, then
  `append` + `start`**. Otherwise `fSimulationRunning` stays at 1, `LocationProvider is notifying
  clients` never fires, and clients never receive the new position.

### Why not intercept the network location request?

macOS's network-based position estimate goes through an HTTPS endpoint built into `locationd`
(`gsp10-ssl.apple.com/hcy/pbcwloc`), protected by certificate trust and device-bound credentials —
and its result is only one input among many in the fusion algorithm, so it both fails to take effect
and gets diluted. With no Wi-Fi associated, that path does not even exist. Going through the
system's own simulated provider is the deterministic route.

---

## Daemon protocol

Unix socket `/var/run/macloc.sock`, one command per line, terminated by `\n`:

| Command | Reply |
|---|---|
| `PING` | `PONG` |
| `SET <lat> <lon>` | `OK <lat> <lon>` / `ERR <CODE> [detail]` |
| `OFF` | `OK off` / `ERR <CODE> [detail]` |
| `SYNC <lat> <lon> <on>` | `OK sync` (updates the state file only, no preference write) |
| `STATUS` | `ON <lat> <lon>` / `OFF` |
| `QUIT` | `OK quit` (tell the daemon to stand down) |

Error codes:

| CODE | Meaning |
|---|---|
| `INVALID_COORD` | Coordinates out of range (lat -90..90, lon -180..180) |
| `NO_PREF_FILE` | No usable locationd preference file found |
| `UNKNOWN_CMD` | Unknown command |
| `PERMISSION` | Neither the console user nor root |
| `WRITE_FAILED` | Failed to write preferences / state |
| `BAD_ARGS` | Wrong number of arguments |
| `RESTART_FAILED` | `locationd` failed to restart |
| `VERIFY_FAILED` | Read-back verification mismatch |

```bash
printf 'SET 999 999\n' | nc -U /var/run/macloc.sock
# ERR INVALID_COORD latitude must be -90..90, longitude -180..180
```

---

## Verifying

**Most direct**: open Apple Maps — the blue dot should be on the target city.

```bash
open -a Maps
```

**Automated** (open Maps → screenshot → find the blue dot → save a close-up):

```bash
./verify.sh
open ~/.macloc/verify.png
```

How it works: the "current location" blue dot in Apple Maps measures `RGB(0,145,255)`, and
`tools/finddot` clusters that color in the screenshot to locate it. The script prints the pixel
coordinates and writes `~/.macloc/verify.png`.

**Read the log**:

```bash
/usr/bin/log show --predicate 'process == "locationd"' --last 2m --style compact | grep -i simul
```

| Log line | Meaning |
|---|---|
| `Using simulated location from defaults` | The preferences channel is active |
| `@ClxProvider, start, simulated` | The simulated provider started |
| `@ClxSimulated, Fix, ...` | Simulated fixes are being produced (one per second) |
| `@ClxClient, Fix, ...` | A fix was delivered to a client |
| `Sending location to client ... com.apple.Maps` | The blue dot has updated |
| `Setting simulation to 1 for all location providers` | The XPC channel is active |
| `location disabled system-wide` | **The Location Services master switch is off** |
| `unentitled client attempting to simulate location` | Entitlement check failed |

Coordinates in the log are `<private>` / `<redacted>` — **the only way to confirm them is the Maps
blue dot**.

---

## Known limits

1. **The target app needs its own Location Services permission (TCC).**
   Without it → `kCLErrorDomain error 1`. System components are exempt.

2. **IP-based geolocation is a separate path and cannot be fooled.**
   The log shows `got response from GeoServices about IP-based country` — that path derives the
   country from the **IP address + Wi-Fi fingerprint** and still reports the real network location.
   Services that geolocate by IP (a lot of fraud detection) will see through it.

3. **Time zone / region are not written by the simulation.**
   `TimeZone.bundle` also consumes locationd's position, so leaving simulation on for a long time may
   let the system drift along with it.

4. **Changing coordinates requires restarting `locationd` (channels A/B).**
   The coordinates themselves are persistent (they live on disk), but `locationd` will not re-read
   them until it restarts.

5. **Intel Macs are not supported** (see [prerequisites](#hard-requirements)).

---

## Uninstalling

```bash
./stop.sh                                  # turn simulation off, restore the original preferences
./install-login.sh --remove                # remove the login item, if installed

sudo rm -f /Library/LaunchDaemons/com.macloc.agent.plist
sudo launchctl bootout system/com.macloc.agent   # unload the daemon
sudo rm -rf /usr/local/libexec/macloc /var/db/macloc /var/log/maclocd.log

rm -rf ~/.macloc                           # user-side log / state copy
rm -rf /Applications/MacLocBar.app        # the graphical UI
```

The Location Services master switch stays on (so you can use it again later). To restore it fully,
turn it off manually in "System Settings → Privacy & Security → Location Services".

---

## What it changes on your system

| Location | Action |
|---|---|
| `/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd.*.plist` | Writes / restores the simulated coordinates and switches |
| `/Library/Managed Preferences/com.apple.locationd.plist` | Same (MCX fallback) |
| `locationd` / `cfprefsd` | Restarted |
| `/Library/LaunchDaemons/com.macloc.agent.plist` | Installs a system-domain launchd job (on demand, never resident) |
| `/usr/local/libexec/macloc/maclocd` | The daemon binary (root) |
| `/var/db/macloc/` | State + backup of the original preferences |
| `/var/log/maclocd.log` | Daemon log |
| `/Applications/MacLocBar.app` | The graphical UI |
| `~/Library/LaunchAgents/com.macloc.bar.plist` | Login item — **not installed by default** |

Everything is reversible; `./stop.sh` plus the uninstall steps above restore the machine.

---

## Security design

- **Privilege escalation goes through the native macOS authorization dialog**
  (`osascript ... with administrator privileges`). `sudoers` is never modified, passwordless sudo is
  never required, and the password is never written to disk.
- **Coordinates can never be executed as a command.** Arguments are normalized to a plain
  `%.6f %.6f` numeric string (range -90..90 / -180..180) and rejected otherwise; inside the root
  script the coordinates only ever appear as `LAT="51.494330"` and take part in no command
  concatenation.
- **Root only touches constant paths**, skips symlinks, and only accepts regular files owned by
  `root` or `_locationd`.
- **The daemon never writes into the user's home directory.** The authoritative state lives in
  `/var/db/macloc/state` (root-owned); `~/.macloc/state` is only a read-only fallback copy.
- **The socket is mode 0666, but the daemon verifies the peer uid** (`getpeereid`): only the console
  user or root can use it.
- **Every step checks its return code**; a failure prints `MACLOC_STEP_FAIL: <which step>` and the
  script never claims success it did not achieve. After writing, the values are **read back and
  compared** (tolerance 1e-4) and `locationd` is confirmed to be running again.
- **Turning simulation off restores the original `LocationServicesEnabled`** from the backup instead
  of forcing it to `true`.

Use this only on machines you are authorized to administer. Changing your location makes every
CoreLocation-based program (clock-in, attendance check-in, fraud detection, track logging) read a
different position — doing that to someone else without their knowledge is neither ethical nor usually
allowed by the terms of service.

---

## File map

```
macloc/
├── preflight.sh         prerequisite self check (arch / session / toolchain / SIP / master switch)
├── install.sh           channel A installer (open master switch + write coords + restart locationd)
├── set.sh               change coordinates (restart locationd, prompt for auth)
├── loc.sh               change coordinates (auto-select channel: daemon first, auth prompt fallback)
├── stop.sh              turn simulation off and restore the original state (auto-select channel)
├── status.sh            status (daemon channel / coordinates / active or not)
├── verify.sh            automated verification (open Maps + find blue dot + save close-up)
├── xpc-push.sh          channel C: real-time XPC switching (needs SIP disabled)
├── install-daemon.sh    install the root daemon (password-less channel, socket-activated)
├── install-login.sh     login item (optional, not installed by default)
├── build-ui.sh          build MacLocBar.app (menu bar UI + main window, installs into /Applications)
├── build-icon.sh        generate the App icon (.icns: dark / light / neon)
├── lib/macloc.sh        shared library (privilege escalation / coordinate sanitizing / state / output)
├── lib/apply-coords.sh  the core logic that writes locationd preferences as root (constant paths)
├── daemon/maclocd.swift root daemon source (unix socket service + on demand + idle exit + QUIT)
├── daemon/LaunchShim.h  C shim: fetch the socket fd handed over by launchd (adapts to both layouts)
├── spoof.dylib.m        source of the injected dylib for channel C (arm64e)
├── ui/MacLocBar.swift   UI source (NSStatusItem + main window + zh/en i18n)
├── ui/AppIcon.icns      App icon (from 1024×1024, 10 sizes)
├── tools/uitest.sh      end-to-end UI test (AXPress the buttons + verify the result)
├── tools/loctest-app.sh build a third-party .app probe to verify the spoof is system-wide
├── tools/loctest.swift  probe source (CoreLocation point of view)
├── tools/finddot.m      locate the "current location" blue dot in a screenshot
├── tools/makeicon.swift App icon generator (pure CoreGraphics)
├── tools/click.m        simulated clicks (for automation)
├── tools/winid.m        print the app's CGWindowNumber
├── tools/menubarpos.m   locate the MacLoc icon in a menu bar screenshot
└── README.md
```

Runtime files:

| Path | Contents |
|---|---|
| `~/.macloc/` | user-side log, coordinate file, state fallback copy, verification screenshots |
| `/var/db/macloc/state` | authoritative state (root-owned) |
| `/var/db/macloc/backup` | backup of the original preferences (root-owned, `0700`) |
| `/var/log/maclocd.log` | daemon log |

---

## Contributors

| | |
|---|---|
| [Rick-Song1999](https://github.com/Rick-Song1999) | project owner, maintenance, releases |
| [anomalyco](https://github.com/anomalyco) (opencode) | implementation |
| [MiniMax-AI](https://github.com/MiniMax-AI) | implementation |

Most of the code in this repository was written by AI coding agents (opencode + MiniMax). The
`Co-authored-by` trailers in the commit history are what GitHub uses for contributor attribution,
and they point at the two accounts above.

---

## License

MIT — see [LICENSE](LICENSE).
