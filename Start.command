#!/bin/zsh
set -eu
cd -- "${0:A:h}"
if [[ ! -x .venv/bin/python || ! -f config.json ]]; then
  printf 'Run Setup.command and edit config.json first.\n'
  read 'reply?Press Enter to close. '
  exit 1
fi
printf 'Experimental, temporary change for your own PS5 and Portal.\nDisconnect Portal from PS5. Keep PS5 powered on.\nSelect target: 65 (default), 100, or 200 Mbps (experimental).\n'
read 'profile?Target [65]: '
profile=${profile:-65}
[[ "$profile" == 65 || "$profile" == 100 || "$profile" == 200 ]] || exit 1
read 'reply?Press Enter; connect Portal only after READY appears. '
set +e
sudo .venv/bin/python portal_active_probe.py --profile "$profile"
result=$?
printf '\nExit status: %s. Read the result above.\n' "$result"
read 'reply?Press Enter to close. '
exit "$result"
