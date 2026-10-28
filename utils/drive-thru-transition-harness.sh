#!/bin/zsh

set -euo pipefail

vm_name="${DRIVETHRU_VM_NAME:-Windows 11}"
primary_player="${DRIVETHRU_PRIMARY_PLAYER:-dryxio}"
secondary_player="${1:-EvasivePanpipe6_CL2}"
timeout_seconds="${2:-1200}"
runner='C:\Mac\Home\Documents\GitHub\mtasa-neon\utils\drive-thru-transition-harness.ps1'

runner_args=(-File "$runner" -PrimaryPlayer "$primary_player" -TimeoutSeconds "$timeout_seconds")
if [[ "$secondary_player" != "-" ]]; then
    runner_args+=(-SecondaryPlayer "$secondary_player")
fi

set +e
prlctl exec "$vm_name" --current-user powershell.exe -NoProfile -ExecutionPolicy Bypass \
    "${runner_args[@]}" 2>&1 |
while IFS= read -r line; do
    print -r -- "$line"
    if [[ "$line" == *"awaiting-ui-W"* || "$line" == *"physical-w"* ]]; then
        # The Windows runner has focused the exact GTA process named by this
        # line. This second path supplies a Parallels/macOS UI event as well as
        # the Win32 scan code; the Lua probe accepts only GTA's real key and
        # analog-control observations plus physical vehicle displacement.
        prlctl send-key-event "$vm_name" --scancode 17 --event press >/dev/null
        osascript -e 'tell application "Parallels Desktop" to activate' \
            -e 'delay 0.1' \
            -e 'tell application "System Events" to keystroke "w"'
        sleep 2
        prlctl send-key-event "$vm_name" --scancode 17 --event release >/dev/null
    fi
done
runner_status=${pipestatus[1]}
set -e
exit "$runner_status"
