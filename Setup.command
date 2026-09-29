#!/bin/zsh
set -eu
cd -- "${0:A:h}"
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
if [[ ! -f config.json ]]; then
  cp config.example.json config.json
fi
printf '\nEdit config.json with your interface and device IP addresses before running.\n'
read 'reply?Press Enter to close. '
