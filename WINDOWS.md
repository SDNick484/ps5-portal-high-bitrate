# Windows preview — unpublished, physical-device validation pending

See [Turkish test instructions](WINDOWS.tr.md). This preview shares the macOS packet transform but uses Npcap on native Windows 10/11. It has not been run on Windows hardware yet. Do not describe local offline tests as Windows runtime validation.

Install Python 3.10+ with the `py` launcher and [Npcap](https://npcap.com/#download), then extract the entire ZIP and run `Setup-Windows.cmd`. Do not enable monitor mode. Use only your own two devices on one directly connected LAN; the selected adapter must have IPv4 forwarding disabled. No firewall, registry or IP forwarding settings are changed.

Run these files as administrator in order:

1. `Configure-Windows.cmd`: select the LAN adapter and enter current PS5/Portal IPv4 addresses.
2. `Check-Windows.cmd`: read-only checks and two-peer ARP resolution.
3. `Baseline-Windows.cmd`: disconnect Portal, press Enter, reconnect only after READY. A bounded relay without payload mutation checks acceptance and cleanup. Visually confirm normal play.
4. `Start-Windows.cmd`: start with 65, then separately test 100/200 only after successful baseline and normal play. Each test needs a fresh Portal session after READY.

The relay window is 40 seconds including warm-up; setup and cleanup add time. A detached 50-second watchdog must signal readiness before ARP changes. A machine-wide named kernel object blocks overlapping experiments on that Windows machine. Do not run a Mac relay simultaneously. Ctrl+C triggers cleanup; power loss cannot be recovered by a watchdog on the same computer.

Independent local egress verification uses a separate Npcap handle and stores only hashes, not raw packets. It is not proof of remote delivery. A successful call sending restoration packets does not independently prove the peers updated their ARP caches. No resolution fields are changed. Input latency and sustained bitrate are not benchmarked.

On restoration error, keep the PC on for at least 60 seconds and inspect `experiments/<run>/recovery-state.recovery.json` and `watchdog.log`. Once no experiment/watchdog is running, an elevated terminal can retry `".venv\Scripts\python.exe" portal_windows.py --restore "experiments\<run>\recovery-state.json"`. Use only a state file created by this tool. Reconnect the peers' network interfaces if necessary. Disconnect/reconnect Portal normally to undo the bitrate request.

Do not publish configuration, recovery state or baseline receipts; they contain local network identifiers. Share redacted `report.json` plus Portal FPS/resolution/bitrate and subjective responsiveness. Raw secrets/firmware/session data are not bundled. No telemetry.
