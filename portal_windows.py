"""Experimental Windows community preview. Never runs network changes on import."""
import argparse
import collections
import datetime
import hashlib
import json
import signal
import subprocess
import sys
import time
from pathlib import Path
import portal_active_probe as core
import portal_windows_network as net

PROFILES = {'65': ('04', 50_000_000), '100': ('03501b0005', 80_000_000), '200': ('00501b0005', 160_000_000)}


def set_profile(profile):
    delta, threshold = PROFILES[profile]
    core.OFFSET = 334
    core.PATCH_DELTA = bytes.fromhex(delta)
    core.CONFIRM_TARGET = threshold
    core.PROFILE_LABEL = profile + 'mbps_experimental_windows'
    core.network = net


def digest(frame):
    if len(frame) < 34 or frame[12:14] != b'\x08\x00':
        return None
    size = int.from_bytes(frame[16:18], 'big')
    if size < 20 or len(frame) < 14 + size:
        return None
    return hashlib.sha256(frame[14:14 + size]).hexdigest()


class Witness:
    """Separate Npcap handle; hashes only, no raw session capture written."""
    def __init__(self, state):
        self.sock = net.open_socket(f'ether src {state["own_mac"]} and ip and host {net.PS5} and host {net.PORTAL} and udp port 9296 and (udp[8] & 15 = 0)')
        self.expected, self.found = set(), set()
        self.count = 0
        self.error = None

    def drain(self):
        try:
            # Bound work per loop even on a noisy network.
            for _ in range(128):
                _, raw, _ = self.sock.recv_raw()
                if not raw:
                    break
                self.count += 1
                value = digest(raw)
                if value and len(self.found) < 20000:
                    self.found.add(value)
        except Exception as exc:
            self.error = type(exc).__name__
            raise

    def report(self):
        return {'expected_unique_modified_packets': len(self.expected),
                'matched_unique_modified_packets': len(self.expected & self.found),
                'captured_egress_packets': self.count, 'read_error': self.error,
                'all_expected_observed': bool(self.expected) and not self.error and self.expected <= self.found,
                'limit': 'Separate local Npcap handle; not proof of PS5 delivery.'}


def baseline_ok(report):
    events = report['ps5_messages']
    return (report['completed'] and not report.get('run_error') and not report['restoration_errors']
            and report['counts'].get('forwarded_in', 0) > 0 and report['counts'].get('forwarded_out', 0) > 0
            and any(e['type'] == 'BANG' and e.get('key_accepted') == 1 and e.get('version_accepted') == 1 for e in events)
            and any(e['type'] == 'STREAMINFO' for e in events))


def result_code(report):
    if report['restoration_errors']:
        return 2
    if report['mode'] == 'baseline':
        return 0 if baseline_ok(report) else 1
    return 0 if (report['completed'] and not report.get('run_error') and report['high_target_confirmed']
                 and report['egress_witness']['all_expected_observed']) else 1


def watchdog(path):
    lock = net.MachineLock(existing=True)
    try:
        state = json.loads(path.read_text())
        net.configure(state['config'])
        # Prove this recovery process can open the adapter before announcing ready.
        check = net.open_socket()
        check.close()
        path.with_suffix('.ready').write_text('ready')
        time.sleep(50)
        errors = net.restore(state)
        path.with_suffix('.recovery.json').write_text(json.dumps({'restoration_errors': errors}, indent=2))
    finally:
        lock.close()


def run(profile, baseline=False):
    net.require_windows()
    c = net.configure()
    state = net.preflight(c)
    set_profile(profile)
    if not baseline:
        receipt = net.ROOT / 'windows-baseline.json'
        previous = json.loads(receipt.read_text()) if receipt.exists() else {}
        if previous.get('config') != state['config'] or not previous.get('baseline_ok'):
            raise RuntimeError('Run Check-Windows.cmd and Baseline-Windows.cmd successfully before changing bitrate.')
    lock = net.MachineLock()
    rx = witness = watcher = log = None
    altered = completed = False
    errors, events, seen = [], [], set()
    counts, rates = collections.Counter(), collections.Counter()
    confirmation = core.TargetConfirmation()
    run_error = None
    folder = net.ROOT / 'experiments' / ('windows-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    old_signal = signal.getsignal(signal.SIGINT)
    try:
        if baseline:
            (net.ROOT / 'windows-baseline.json').unlink(missing_ok=True)
        folder.mkdir(parents=True)
        saved = folder / 'recovery-state.json'
        saved.write_text(json.dumps(state))
        rx = net.open_socket(f'ether dst {state["own_mac"]} and ip and host {net.PS5} and host {net.PORTAL}')
        witness = Witness(state)
        log = (folder / 'watchdog.log').open('w')
        watcher = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--watchdog', str(saved)],
                                   creationflags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        deadline = time.monotonic() + 10
        while not saved.with_suffix('.ready').exists():
            if watcher.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Recovery watchdog did not become ready; no network changes made.')
            time.sleep(.05)
        def interrupted(sig, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGINT, interrupted)
        print('Preparing network path. Keep Portal disconnected until READY.', flush=True)
        start = time.monotonic()
        next_arp = start
        announced = False
        while time.monotonic() - start < 40:
            now = time.monotonic()
            if watcher.poll() is not None:
                raise RuntimeError('Recovery watchdog exited unexpectedly.')
            if now >= next_arp:
                altered = True
                for frame in net.frames(state):
                    net.send_raw(rx, frame)
                next_arp = now + 1
            if not announced and now - start >= 5:
                announced = True
                print('READY / HAZIR: connect Portal to PS5 now.', flush=True)
            witness.drain()
            _, raw, _ = rx.recv_raw()
            if not raw:
                time.sleep(.001)
                continue
            item = core.transform(raw, state, not baseline)
            if item is None:
                continue
            outbound, payload, direction, changed = item
            net.send_raw(rx, outbound)
            counts['forwarded_' + direction] += 1
            if changed:
                witness.expected.add(digest(outbound))
                counts['mutated_packets_including_retransmits'] += 1
                seq = payload[17:21]
                if seq not in seen:
                    seen.add(seq)
                    confirmation.modified()
                    print('Startup packet modified; waiting for PS5 target.', flush=True)
            if payload is not None and direction == 'in':
                rates[int(now-start)] += len(payload)
                observed = []
                core.observe(payload, observed)
                events.extend(observed)
                for event in observed:
                    confirmation.observe(event)
            if not baseline and confirmation.ready and witness.report()['all_expected_observed']:
                print('High target observed; restoring direct path.', flush=True)
                break
        completed = True
    except KeyboardInterrupt:
        run_error = 'Interrupted; restoring direct path.'
    except Exception as exc:
        run_error = f'{type(exc).__name__}: {exc}'
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if altered:
            try:
                errors = net.restore(state)
            except Exception as exc:
                errors = ['Unexpected restore failure: ' + type(exc).__name__]
        if witness:
            try:
                witness.drain()
            except Exception:
                pass
            try:
                witness.sock.close()
            except Exception as exc:
                errors.append('Witness close: ' + type(exc).__name__)
        if rx:
            try:
                rx.close()
            except Exception as exc:
                errors.append('Relay close: ' + type(exc).__name__)
        if watcher and not errors:
            watcher.terminate()
            try:
                watcher.wait(timeout=5)
            except subprocess.TimeoutExpired:
                watcher.kill()
                watcher.wait(timeout=5)
        # If restore fails, keep the detached watchdog alive and its mutex handle held.
        if log:
            log.close()
        lock.close()
        signal.signal(signal.SIGINT, old_signal)
    report = {'mode': 'baseline' if baseline else core.PROFILE_LABEL, 'completed': completed,
              'run_error': run_error, 'counts': dict(counts), 'unique_mutated_sequences': len(seen),
              'ps5_messages': events, 'high_target_confirmed': confirmation.ready,
              'egress_witness': witness.report() if witness else {'all_expected_observed': False},
              'restoration_errors': errors,
              'udp_9296_mbps_by_second': {str(k): round(v*8/1e6,3) for k,v in sorted(rates.items())},
              'limits': ['Windows preview has not yet been validated on physical devices.',
                         'Target is not measured video throughput; no resolution fields changed.',
                         'ARP restoration sends were checked locally, not independently confirmed at peers.']}
    if folder.exists():
        (folder/'report.json').write_text(json.dumps(report, indent=2))
    if baseline and baseline_ok(report):
        (net.ROOT/'windows-baseline.json').write_text(json.dumps({'baseline_ok':True,'config':state['config']}))
    print(json.dumps(report, indent=2))
    print('Report:', folder/'report.json')
    if errors:
        print('Restoration failed. Leave PC running for watchdog recovery; see WINDOWS.tr.md.')
    elif result_code(report):
        print('NOT CONFIRMED. Code 1 does not prove session failure; inspect targets and mutation count.')
    else:
        print('Baseline passed.' if baseline else 'High target and local egress verified; check actual Portal quality.')
    return result_code(report)


def setup():
    net.require_windows()
    adapters = [x for x in net.conf.ifaces.values() if x.mac and x.ip and x.ip != '0.0.0.0']
    for i, a in enumerate(adapters, 1):
        print(f'{i}: {a.name} ({a.description}) - {a.ip}')
    number = int(input('LAN adapter number: '))
    if not 1 <= number <= len(adapters):
        raise ValueError('Invalid adapter selection.')
    c = {'interface': adapters[number-1].network_name,
         'ps5_ip': input('PS5 IPv4: ').strip(), 'portal_ip': input('Portal IPv4: ').strip()}
    net.validate_config(c)
    (net.ROOT/'config.windows.json').write_text(json.dumps(c, indent=2))
    print('Configuration saved locally. Run Check-Windows.cmd next.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--setup', action='store_true')
    group.add_argument('--check', action='store_true')
    group.add_argument('--baseline', action='store_true')
    group.add_argument('--watchdog', type=Path)
    group.add_argument('--restore', type=Path)
    parser.add_argument('--profile', choices=PROFILES, default='65')
    args = parser.parse_args()
    net.require_windows()
    if args.watchdog:
        watchdog(args.watchdog); return 0
    if args.restore:
        # Acquire exclusive lock: don't restore over an active relay/watchdog.
        lock = net.MachineLock()
        try:
            errors = net.restore(json.loads(args.restore.read_text()))
            print(errors or 'Restoration sends completed.')
            return 2 if errors else 0
        finally:
            lock.close()
    if args.setup:
        setup(); return 0
    if args.check:
        c=net.configure(); net.preflight(c)
        sock=net.open_socket(); sock.close()
        print('CHECK PASSED: peers resolved, direct route, forwarding disabled, Npcap opened. No ARP mappings changed.')
        return 0
    return run(args.profile, args.baseline)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'ERROR: {type(exc).__name__}: {exc}', file=sys.stderr)
        raise SystemExit(2)
