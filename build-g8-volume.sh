#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
stage=$(mktemp -d "$PWD/build/stage.XXXXXX")
app="$stage/G8 Volume.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -O -warnings-as-errors -framework AppKit -framework ApplicationServices -framework CoreAudio \
    G8VolumeKeys.swift -o "$app/Contents/MacOS/G8VolumeKeys"
cp G8VolumeKeys-Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/G8VolumeKeys" --self-test
"$app/Contents/MacOS/G8VolumeKeys" --ui-self-test
"$app/Contents/MacOS/G8VolumeKeys" --status
printf '%s\n' "$app" > build/verified-app-path
printf '\nVerified build: %s\n' "$app"
if [[ "${1:-}" == "--install" ]]; then
    python3 - "$app" <<'PY'
import hashlib, os, pathlib, shutil, subprocess, sys, time, uuid
source = pathlib.Path(sys.argv[1])
target = pathlib.Path.home() / "Applications/G8 Volume.app"
stage = target.parent / (".g8-install-" + uuid.uuid4().hex)
backup = source.parent / "replaced-G8-Volume.app"
def run(*args):
    subprocess.run(args, check=True)
def digest(app):
    return hashlib.sha256((app / "Contents/MacOS/G8VolumeKeys").read_bytes()).hexdigest()
shutil.copytree(source, stage)
run("/usr/bin/codesign", "--verify", "--strict", str(stage))
assert digest(source) == digest(stage)
pids = subprocess.run(["/usr/bin/pgrep", "-x", "G8VolumeKeys"], capture_output=True, text=True).stdout.split()
for pid in pids:
    try: os.kill(int(pid), 15)
    except ProcessLookupError: pass
deadline = time.monotonic() + 5
while pids and time.monotonic() < deadline:
    remaining = []
    for pid in pids:
        try: os.kill(int(pid), 0); remaining.append(pid)
        except ProcessLookupError: pass
    pids = remaining
    if pids: time.sleep(0.1)
if pids:
    raise SystemExit("Old process did not exit; installation stopped")
if target.exists(): target.rename(backup)
try:
    stage.rename(target)
    run("/usr/bin/codesign", "--verify", "--strict", str(target))
    assert digest(source) == digest(target)
    run("/usr/bin/open", str(target))
except Exception:
    if target.exists(): target.rename(source.parent / "failed-install.app")
    if backup.exists(): backup.rename(target)
    raise
print("Installed verified binary SHA256:", digest(target))
PY
fi
