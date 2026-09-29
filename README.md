# PS5 Portal High Bitrate

Experimental **macOS** launcher for temporarily requesting a higher PS5 Remote Play bitrate on your own PlayStation Portal. Includes 65, 100 and experimental 200 Mbps target profiles, a bounded relay, independent packet-egress verification, and network restoration.

**This is not a jailbreak, a 4K unlock, or a guaranteed latency improvement.** A single Portal running firmware **7.1.7** was tested. Other firmware, network layouts and consoles are unverified. The tool matches a recorded packet layout, not a verified firmware identity; a matching packet length alone does not guarantee compatible plaintext offsets.

[Türkçe kullanım](README.tr.md)

## Observed results

| Profile | PS5-reported target | Owner observation |
| --- | --- | --- |
| 65 Mbps | approximately 63.106 Mbps | approximately 58 Mbps on Portal; visibly cleaner picture |
| 100 Mbps | approximately 97.087 Mbps | peaks around 84 Mbps on Portal |
| 200 Mbps (experimental) | initially 166.141 Mbps, then approximately 158.3 Mbps | qualitative positive feedback; actual sustained throughput not established |
| Separate 4K experiment | approximately 97.087 Mbps | PS5 offered only 720p/540p/360p; visible regression |

The working bitrate-only profile restored 1080p after the 4K experiment. **The failed 4K profile is not included.** These are observations from one setup, not controlled benchmarks. Target bitrate is not actual video throughput. Sustained 100 or 200 Mbps, reduced input lag and universal compatibility have not been demonstrated. Private captures and proprietary firmware are not distributed.

## Requirements

- macOS with Python 3.10 or newer, `sudo`, and the built-in `tcpdump`.
- PS5, Portal and Mac on the same directly connected IPv4 LAN. No guest/client isolation, VPN routing or routed subnets between them.
- Prefer wired Ethernet for PS5. The tested Mac used Wi-Fi; Wi-Fi relaying itself can add loss/latency.
- Administrative access to the Mac and permission to operate both devices. The tool temporarily changes the two devices' ARP mappings and disables ICMP redirects; it does not modify firmware.
- Python dependencies are installed without sudo. Running a downloaded launcher as administrator executes its local Python files: inspect the code and keep its folder writable only by trusted users.

## Setup

Clone or download this repository, then open a Terminal in its folder:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
cp config.example.json config.json
```

Alternatively double-click `Setup.command`. Edit `config.json` with the **actual** PS5 and Portal IPv4 addresses and the Mac interface. The example addresses are documentation placeholders and will not reach your devices. Use DHCP reservations so addresses do not change. Find interface names with `networksetup -listallhardwareports`; Wi-Fi is often `en0`, but not always.

Optional preflight (resolves only the two configured peers; does not change routing/ARP mappings):

```sh
sudo .venv/bin/python portal_capture.py --check
```

## Each new play session

1. Disconnect Portal from PS5; leave PS5 powered on.
2. Double-click `Start.command`, select 65, 100 or 200, and press Enter. Enter the Mac password only at the local sudo prompt.
3. Wait for **READY**, then start a fresh connection on Portal.
4. Look for **Startup packet modified**. The tool restores the direct path after three sufficiently high target reports following acceptance and stream setup, or at the 40-second relay deadline.
5. Read the final status. Once complete, the Mac is no longer relaying the session. No need to leave the launcher running.

Terminal alternative:

```sh
sudo .venv/bin/python portal_active_probe.py --profile 65
# Or choose the more demanding target:
sudo .venv/bin/python portal_active_probe.py --profile 100
```

The five-second warm-up is included in the 40-second relay window. Startup preflight and cleanup add time around it. The independent restoration watchdog waits 55 seconds from its own start. Higher bitrate can increase congestion; compare profiles in the same moving scene. To revert, disconnect and reconnect normally without the launcher. Each new session negotiates its own settings.

### 200 Mbps experiment

```sh
sudo .venv/bin/python portal_active_probe.py --profile 200
```

The original 200 Mbps run applied one mutation, received BANG acceptance and STREAMINFO, and restored the network without errors. Its PS5 targets settled near 158 Mbps, below the 160 Mbps early-exit threshold. Thus it returned status 1 (`UNCONFIRMED`) despite a working session. This profile retains that threshold: success requires three consecutive reports at or above 160 Mbps, not proof of actual 200 Mbps video. The relay-side one-second UDP peak was 75.760 Mbps; no sustained direct-path throughput or latency improvement was measured. Resolution fields are unchanged. Reconnect with 100 or 65 if playback degrades.

## How it works

The Mac temporarily relays only the configured PS5–Portal pair. For a narrowly matched initial Takion BIG packet (client version 20, channel zero, zero GMAC, 2296-byte base64 LaunchSpec), it XORs ciphertext bytes at inferred offset 334. The hypothesis is `25000` → `65000`, or the same-length JSON number `1e+05` for 100 Mbps, or `2e+05` for 200 Mbps. No plaintext decryption or authentication bypass is claimed. The 1080p resolution fields are not changed.

An independent bounded `tcpdump` capture verifies the changed packet appeared on the Mac interface. BANG acceptance, STREAMINFO and consecutive CONNECTIONQUALITY targets gate early exit. These control messages are observed, not cryptographically authenticated by this tool. Local egress verification does not itself prove delivery. Packet matching does not establish device firmware compatibility.

## Troubleshooting and recovery

- **NOT APPLIED:** no matching new handshake was captured. Disconnect, retry, and connect only after READY. Do not infer that PS5 rejected the target.
- **UNCONFIRMED:** a mutation occurred but the required high target sequence was not observed. Reconnect normally or try 65. Do not repeatedly force an unknown firmware layout.
- **Stutter or blurry picture:** compare 65 and 100 before trying 200; higher targets are not always better. Reconnect normally to undo the session change.
- **Restoration failure:** allow the watchdog its 55 seconds. The report includes `watchdog_state`, the private path to the original network state. Retry restoration with `sudo .venv/bin/python portal_capture.py --restore /path/from/report/state.json`. Use only the state file generated by this tool. If a process was force-killed, reconnect the two devices to refresh neighbor mappings.
- **Existing lock:** do not run overlapping experiments. If no experiment or watchdog is running and restoration is complete, remove the stale `/var/run/portal-lab-capture.lock` with sudo. Never delete it while another run is active.

Ctrl-C enters cleanup. A separate watchdog offers recovery if the main process crashes, but cannot recover while the Mac is powered off. Review `restoration_errors` rather than assuming the timer guarantees success.

## Privacy

`config.json`, packet captures and generated reports stay local and are git-ignored. Raw captures can contain session identifiers and network metadata. **Do not attach them to public issues.** Share only a manually redacted summary: firmware version, profile, whether mutation occurred, target reports and restoration status. No telemetry is sent by this project.

## Development

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Tests use synthetic packets and mocked network operations, with no devices or sudo required. CI runs these tests; it does not test a real console. The public packaging and configurable network layer have offline validation; only their source prototype was tested on the owner's devices.

Independent community experiment; not affiliated with Sony or PlayStation. Protocol context: [Chiaki-ng](https://github.com/streetpea/chiaki-ng). No Chiaki source, Sony firmware, firmware keys or captured sessions are bundled. MIT licensed; see LICENSE.
