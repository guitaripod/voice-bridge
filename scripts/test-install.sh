#!/usr/bin/env bash
#
# Runs install.sh offline against a fake release served from this machine, with a throwaway HOME
# and a PATH that holds no swift and no git, and checks what a stranger's install would leave
# behind. Nothing here touches the real ~/.local, ~/.config, a real service manager, a GPU, Docker
# or the network: nvidia-smi, docker, tailscale, systemctl and loginctl on the PATH are stand-ins,
# and every gateway port is one nothing listens on or one this script serves itself.
#
#   scripts/test-install.sh
#
# The first half installs a stand-in program that only knows how to answer --version and doctor. The
# second half repeats the important cases with the real program from .build/debug when it is built
# (swift build), so the installer and the program's own doctor are checked against each other.

# shellcheck disable=SC2016,SC2086,SC2206
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PASSED=0
FAILED=0
SERVER_PID=""

cleanup() {
  [ -z "$SERVER_PID" ] || kill -KILL "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { PASSED=$(( PASSED + 1 )); printf 'ok    %s\n' "$1"; }
flunk() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /'; }

check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else flunk "$name"; fi
}

has() { printf '%s' "$1" | grep -Fq -- "$2"; }

expect_has() {
  if has "$1" "$2"; then pass "$3"; else flunk "$3" "wanted: $2
got:
$(printf '%s' "$1" | tail -30)"; fi
}

expect_lacks() {
  if has "$1" "$2"; then flunk "$3" "did not want: $2"; else pass "$3"; fi
}

PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
case "$PLATFORM" in
  linux-x86_64|linux-aarch64) ;;
  *) printf 'no prebuilt release exists for %s; nothing to test here\n' "$PLATFORM"; exit 0 ;;
esac
VERSION="$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' "$ROOT/CHANGELOG.md" | head -1)"

TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for tool in uname date mkdir mktemp curl tar awk sed head tr cut base64 df sha256sum shasum grep \
  cat chmod mv cp rm touch find dirname sleep hostname id tail ls strip stat gzip ln wc sort cmp timeout; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  [ -z "$path" ] || ln -s "$path" "$TOOLS/$tool"
done
BASH_BIN="$(command -v bash)"

check "the test PATH holds neither swift nor git nor a service manager" \
  bash -c "! PATH='$TOOLS' command -v swift && ! PATH='$TOOLS' command -v git && ! PATH='$TOOLS' command -v systemctl && ! PATH='$TOOLS' command -v docker && ! PATH='$TOOLS' command -v nvidia-smi"

FAKE="$TMP/fake/voice-bridge"
mkdir -p "$TMP/fake"
cat >"$FAKE" <<'FAKE_EOF'
#!/bin/sh
case "${1:-}" in
  --version) echo "voice-bridge 9.9.9" ;;
  doctor)
    case "${2:-}" in
      --json) if [ "${FAKE_DOCTOR:-needs-tailscode}" = ready ]; then echo '{"available":true,"capability":"voice","ready":true}'; else echo '{"available":true,"capability":"voice","ready":false}'; fi; exit 0 ;;
      --commands) [ "${FAKE_DOCTOR:-}" = needs-docker ] && printf 'sudo apt-get install -y docker.io\nsudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml\n'; exit 0 ;;
    esac
    case "${FAKE_DOCTOR:-needs-tailscode}" in
      nogpu) echo "No NVIDIA GPU with 64 GB: voice calls cannot run on this machine. nvidia-smi found no NVIDIA GPU."; exit 3 ;;
      ready) echo "This machine has an NVIDIA RTX PRO 6000 with 96 GB: voice calls can run here."; echo "  ✓ everything"; exit 0 ;;
      *) echo "This machine has an NVIDIA RTX PRO 6000 with 96 GB: voice calls can run here."; echo "  ○ Voice model: not downloaded yet"; exit 0 ;;
    esac ;;
  *) echo "serving" ;;
esac
FAKE_EOF
chmod 755 "$FAKE"
touch -d '2001-01-01' "$FAKE"

WWW="$TMP/www"
mkdir -p "$WWW/good" "$WWW/badsum" "$WWW/noasset" "$WWW/nostart"
"$ROOT/scripts/package-release.sh" --binary "$FAKE" --version 9.9.9 --out "$WWW/good" >"$TMP/package.log" 2>&1
ASSET="voice-bridge-9.9.9-$PLATFORM.tar.gz"
printf '9.9.9\n' >"$WWW/good/latest.txt"
printf 'ok\n' >"$WWW/health"

check "the package script names the archive and its checksum" \
  test -f "$WWW/good/$ASSET" -a -f "$WWW/good/$ASSET.sha256"
check "the archive holds the program, the license and the installer, flat" \
  test "$(tar -tzf "$WWW/good/$ASSET" | LC_ALL=C sort | tr '\n' ' ')" = "LICENSE install.sh voice-bridge "
check "the checksum file verifies with sha256sum" \
  bash -c "cd '$WWW/good' && sha256sum -c '$ASSET.sha256' >/dev/null"
check "the package script refuses a program that reports another version than the changelog" \
  bash -c "! '$ROOT/scripts/package-release.sh' --binary '$FAKE' --version 1.2.3 --out '$TMP/refused' >/dev/null 2>&1"
check "the version the package script reads is the one the changelog heads with" test -n "$VERSION"

cp "$WWW/good/latest.txt" "$WWW/good/$ASSET" "$WWW/badsum/"
printf '%064d  %s\n' 0 "$ASSET" >"$WWW/badsum/$ASSET.sha256"
cp "$WWW/good/latest.txt" "$WWW/noasset/"
cp "$WWW/good/latest.txt" "$WWW/nostart/"
BROKEN="$TMP/broken"
mkdir -p "$BROKEN"
printf '#!/bin/sh\nexit 3\n' >"$BROKEN/voice-bridge"
chmod 755 "$BROKEN/voice-bridge"
tar -czf "$WWW/nostart/$ASSET" -C "$BROKEN" voice-bridge
printf '%s  %s\n' "$(sha256sum "$WWW/nostart/$ASSET" | cut -d' ' -f1)" "$ASSET" >"$WWW/nostart/$ASSET.sha256"

python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$WWW" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
SERVER_PORT=""
for _ in $(seq 1 50); do
  SERVER_PORT="$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$TMP/server.log" | head -1)"
  [ -n "$SERVER_PORT" ] && break
  sleep 0.1
done
[ -n "$SERVER_PORT" ] || { echo "the fake release server did not start"; exit 1; }
SERVER="http://127.0.0.1:$SERVER_PORT"

CLOSED_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

SHIMS=""
HOME_COUNT=0
OUT=""
RC=0
SHARE=""
HOME_DIR=""
SERVICE_LOG="$TMP/service.log"
ACTIVE_FLAG="$TMP/active"

shim() {
  printf '#!/bin/sh\n%s\n' "$2" >"$SHIMS/$1"
  chmod 755 "$SHIMS/$1"
}

fake_gpu_tools() {
  shim nvidia-smi 'echo "NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 97887, 1200"'
  shim docker 'echo 29.8.2'
}

fresh_home() {
  HOME_COUNT=$(( HOME_COUNT + 1 ))
  HOME_DIR="$TMP/home$HOME_COUNT"
  SHARE="$HOME_DIR/.local/share/voice-bridge"
  SHIMS="$TMP/shims$HOME_COUNT"
  mkdir -p "$HOME_DIR" "$SHIMS"
  rm -f "$SERVICE_LOG" "$ACTIVE_FLAG"
  fake_gpu_tools
}

recording_service_shims() {
  local name
  for name in systemctl loginctl; do
    shim "$name" "echo \"$name \$*\" >>'$SERVICE_LOG'
case \"\$*\" in *is-active*) [ -f '$ACTIVE_FLAG' ] && exit 0; exit 1;; esac"
  done
}

env_with_port() {
  mkdir -p "$HOME_DIR/.config"
  printf '# mine\nVOICE_PORT=%s\n' "$1" >"$HOME_DIR/.config/voice-bridge.env"
}

install() {
  local base="$SERVER/good"
  case "${BASE:-}" in "") ;; *) base="$BASE" ;; esac
  local environment=(env -i HOME="$HOME_DIR" USER=tester PATH="$SHIMS:$TOOLS"
    VOICE_RELEASE_BASE="$base" VOICE_HEALTH_ATTEMPTS=2 VOICE_TAILSCALE="$TMP/no-tailscale" ${ENV_EXTRA:-})
  if [ -n "${PIPED:-}" ]; then
    OUT="$(cat "$ROOT/install.sh" | "${environment[@]}" "$BASH_BIN" -s -- "$@" 2>&1)" && RC=0 || RC=$?
  else
    OUT="$("${environment[@]}" "$BASH_BIN" "$ROOT/install.sh" "$@" 2>&1)" && RC=0 || RC=$?
  fi
}

stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

tree_of() { (cd "$1" && find . -type f -o -type l | sort); }

fresh_home
BASE="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "downloading the latest voice-bridge for $PLATFORM" "binary install: says what it is downloading"
check "binary install: succeeds without swift or git" test "$RC" -eq 0
check "binary install: the program lands in the share dir's bin" test -x "$SHARE/bin/voice-bridge"
check "binary install: the installed program runs" test "$("$SHARE/bin/voice-bridge" --version)" = "voice-bridge 9.9.9"
check "binary install: ~/.local/bin/voice-bridge is a link to it" \
  test "$(readlink "$HOME_DIR/.local/bin/voice-bridge")" = "$SHARE/bin/voice-bridge"
check "binary install: no checkout is made" test ! -e "$SHARE/src"
check "binary install: the program is stamped as arriving now, not as built in 2001" \
  test "$(( $(date +%s) - $(stat_mtime "$SHARE/bin/voice-bridge") ))" -lt 300
check "binary install: no download leftovers" test -z "$(find "$SHARE" -maxdepth 1 -name '.download.*')"
check "binary install: the installer that shipped with it is kept for voice-bridge update" \
  bash -c "cmp -s '$SHARE/install.sh' '$ROOT/install.sh' && test -x '$SHARE/install.sh'"
check "binary install: writes the env file" test -f "$HOME_DIR/.config/voice-bridge.env"
check "binary install: the env file is private" test "$(stat -c %a "$HOME_DIR/.config/voice-bridge.env" 2>/dev/null || stat -f %Lp "$HOME_DIR/.config/voice-bridge.env")" = 600
check "binary install: the env file has every setting commented out, so the defaults apply" \
  bash -c "! grep -Eq '^[A-Z_]+=' '$HOME_DIR/.config/voice-bridge.env' && grep -Fq '# VOICE_PORT=4102' '$HOME_DIR/.config/voice-bridge.env'"
check "--no-service: no unit is written" test ! -e "$HOME_DIR/.config/systemd"
expect_has "$OUT" "Tailscale: not installed" "pre-flight: reports a missing Tailscale"
expect_has "$OUT" "https://tailscale.com/download" "pre-flight: says where to get Tailscale"
expect_has "$OUT" "restart the gateway so it picks up the address" "pre-flight: says the gateway must be restarted once Tailscale is up"
expect_has "$OUT" "wrote $HOME_DIR/.config/voice-bridge.env" "binary install: says it wrote the env file"
expect_has "$OUT" "What voice needs on this computer:" "ending: runs the program's own check"
expect_has "$OUT" "This machine has an NVIDIA RTX PRO 6000 with 96 GB: voice calls can run here." "ending: shows the hardware verdict"
expect_has "$OUT" "What is left to do:" "ending: lists what is left"
expect_has "$OUT" "Open Tailscode, pick this server and tap Set up voice." "ending: says the rest happens in Tailscode"
expect_has "$OUT" "installed but not started" "ending: says it did not start a service"
expect_lacks "$OUT" "sudo apt-get" "ending: no administrator command when none is needed"
expect_lacks "$OUT" "Building from source" "binary install: never mentions a source build"

before_listing="$(tree_of "$HOME_DIR")"
before_env="$(cksum <"$HOME_DIR/.config/voice-bridge.env")"
before_time="$(stat_mtime "$SHARE/bin/voice-bridge")"
sleep 1
BASE="" ENV_EXTRA="" install --no-service
check "re-run: succeeds" test "$RC" -eq 0
check "re-run: leaves the same files behind" test "$(tree_of "$HOME_DIR")" = "$before_listing"
check "re-run: keeps the env file" test "$(cksum <"$HOME_DIR/.config/voice-bridge.env")" = "$before_env"
check "re-run: puts the program in place again" test "$(stat_mtime "$SHARE/bin/voice-bridge")" -gt "$before_time"
expect_has "$OUT" "kept your settings in $HOME_DIR/.config/voice-bridge.env" "re-run: says it kept the env file"

fresh_home
mkdir -p "$HOME_DIR/.config"
printf 'VOICE_PASSWORD=hunter2\nVOICE_PORT=4999\n# my own note\n' >"$HOME_DIR/.config/voice-bridge.env"
chmod 640 "$HOME_DIR/.config/voice-bridge.env"
before_env="$(cksum <"$HOME_DIR/.config/voice-bridge.env")"
BASE="" ENV_EXTRA="" install --no-service
check "an env file that is already there is never overwritten" test "$(cksum <"$HOME_DIR/.config/voice-bridge.env")" = "$before_env"
check "an env file that is already there keeps its permissions" \
  test "$(stat -c %a "$HOME_DIR/.config/voice-bridge.env" 2>/dev/null || stat -f %Lp "$HOME_DIR/.config/voice-bridge.env")" = 640
expect_has "$OUT" "kept your settings" "an env file that is already there: says so"
expect_lacks "$OUT" "hunter2" "an env file that is already there: the password is never printed"

fresh_home
BASE="" ENV_EXTRA="FAKE_DOCTOR=nogpu" install --no-service
check "no GPU: stops with exit 3" test "$RC" -eq 3
expect_has "$OUT" "No NVIDIA GPU with 64 GB: voice calls cannot run on this machine." "no GPU: says so in the program's words"
expect_has "$OUT" "Nothing was installed." "no GPU: says nothing was installed"
expect_has "$OUT" "--force" "no GPU: offers --force"
check "no GPU: no program, link, env file, unit or installer is left behind" \
  bash -c "test ! -e '$SHARE/bin' && test ! -e '$HOME_DIR/.local/bin' && test ! -e '$HOME_DIR/.config' && test ! -e '$SHARE/install.sh' && test -z \"\$(find '$SHARE' -maxdepth 1 -name '.download.*')\""
expect_lacks "$OUT" "What is left to do" "no GPU: no list of chores for a machine that cannot do it"

BASE="" ENV_EXTRA="FAKE_DOCTOR=nogpu" install --no-service --force
check "no GPU with --force: installs" test "$RC" -eq 0 -a -x "$SHARE/bin/voice-bridge"
expect_has "$OUT" "cannot run voice calls (see above); the gateway was installed because of --force" "no GPU with --force: says why it is there"
expect_lacks "$OUT" "tap Set up voice" "no GPU with --force: does not send the person to Tailscode for a setup that cannot work"

fresh_home
rm -f "$SHIMS/nvidia-smi"
BASE="$SERVER/badsum" ENV_EXTRA="" install --no-service
check "no GPU and a source build ahead: told before anything is cloned" test "$RC" -eq 3
expect_has "$OUT" "nvidia-smi is not installed" "no GPU and a source build ahead: says why, before the wait"
expect_lacks "$OUT" "cloning" "no GPU and a source build ahead: nothing is cloned"

fresh_home
recording_service_shims
env_with_port "$SERVER_PORT"
BASE="" ENV_EXTRA="VOICE_UNIT=voice-bridge.service" install
check "service: succeeds" test "$RC" -eq 0
check "service: the unit is exactly the packaged one" cmp -s "$ROOT/packaging/voice-bridge.service" "$HOME_DIR/.config/systemd/user/voice-bridge.service"
check "service: the external unit is copied with this machine's paths" \
  bash -c "grep -Fq -- '--entrypoint /s2s/run_s2s_server.sh nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest' '$HOME_DIR/.config/systemd/user/nemotron-voicechat.service' && grep -Fq -- '-v %h/.local/share/voice-bridge/model/nemotron-labs-voicechat_v1.0.0:/data/models' '$HOME_DIR/.config/systemd/user/nemotron-voicechat.service' && grep -Fq 'ExecStart=$SHIMS/docker run' '$HOME_DIR/.config/systemd/user/nemotron-voicechat.service'"
check "service: the external unit matches the packaged one apart from the docker path" \
  bash -c "diff <(sed 's#$SHIMS/docker#/usr/bin/docker#' '$HOME_DIR/.config/systemd/user/nemotron-voicechat.service') '$ROOT/packaging/nemotron-voicechat.service' >/dev/null"
check "service: the unit is enabled and started as a user service, and only that one" \
  bash -c "grep -Fxq 'systemctl --user daemon-reload' '$SERVICE_LOG' && grep -Fxq 'systemctl --user enable --now voice-bridge.service' '$SERVICE_LOG' && ! grep -q 'nemotron' '$SERVICE_LOG' && ! grep -Eq 'restart|stop|kill|disable|mask' '$SERVICE_LOG'"
expect_has "$OUT" "started voice-bridge.service; it comes back after a reboot" "service: says what it started"
expect_has "$OUT" "copied nemotron-voicechat.service (not enabled" "service: says the external unit is not enabled"
expect_has "$OUT" "voice-bridge is running." "ending: says running once the gateway answers"

BASE="" ENV_EXTRA="" install
check "service re-run: keeps the unit it wrote" bash -c "test \"\$(grep -c 'enable --now' '$SERVICE_LOG')\" = 2"
expect_has "$OUT" "kept the existing voice-bridge.service" "service re-run: says it kept the unit"
printf '# mine\n' >>"$HOME_DIR/.config/systemd/user/voice-bridge.service"
BASE="" ENV_EXTRA="" install
check "service re-run: an edited unit survives" grep -Fxq '# mine' "$HOME_DIR/.config/systemd/user/voice-bridge.service"

fresh_home
recording_service_shims
env_with_port "$SERVER_PORT"
touch "$ACTIVE_FLAG"
BASE="" ENV_EXTRA="" install
check "a gateway that is already running: the install succeeds" test "$RC" -eq 0
check "a gateway that is already running: it is never restarted, stopped or killed" \
  bash -c "! grep -Eq 'restart|stop|kill|reload-or-restart' '$SERVICE_LOG'"
expect_has "$OUT" "voice-bridge.service was already running and was left running" "a gateway that is already running: says so"
expect_has "$OUT" "keeps running the program it started with" "a gateway that is already running: says it has not changed"
expect_has "$OUT" "voice-bridge update" "a gateway that is already running: says how to switch over"

fresh_home
recording_service_shims
env_with_port "$CLOSED_PORT"
BASE="" ENV_EXTRA="" install
expect_has "$OUT" "is installed, but it is not answering on port $CLOSED_PORT" "ending: does not claim a gateway that does not answer is running"
expect_has "$OUT" "journalctl --user -u voice-bridge.service" "ending: says where to look"
expect_lacks "$OUT" "voice-bridge is running." "ending: no false running"

fresh_home
shim systemctl 'echo "Failed to connect to bus" >&2; exit 1'
BASE="" ENV_EXTRA="" install
check "no user service manager: the install still succeeds" test "$RC" -eq 0 -a -x "$SHARE/bin/voice-bridge"
expect_has "$OUT" "no user service manager answered here" "no user service manager: says so"
expect_has "$OUT" "Start the gateway yourself" "no user service manager: and what to do"

fresh_home
shim tailscale 'case "$1" in status) echo "Logged out."; echo "Log in at: https://login.tailscale.com/a/x"; exit 1;; esac'
BASE="" ENV_EXTRA="VOICE_TAILSCALE=$SHIMS/tailscale" install --no-service
expect_has "$OUT" "Tailscale: installed, but not signed in" "pre-flight: a signed-out Tailscale is named"
expect_has "$OUT" "sudo tailscale up" "pre-flight: and the fix is given"
check "pre-flight: the install carries on regardless" test "$RC" -eq 0 -a -x "$SHARE/bin/voice-bridge"

fresh_home
shim tailscale 'case "$1" in status) echo "Tailscale is stopped."; exit 1;; esac'
BASE="" ENV_EXTRA="VOICE_TAILSCALE=$SHIMS/tailscale" install --no-service
expect_has "$OUT" "Tailscale: installed, but turned off" "pre-flight: a stopped Tailscale is named"

fresh_home
shim tailscale 'case "$1" in status) echo "100.64.0.7 box tester linux -"; exit 0;; ip) echo 100.64.0.7;; esac'
BASE="" ENV_EXTRA="VOICE_TAILSCALE=$SHIMS/tailscale FAKE_DOCTOR=ready" install --no-service
expect_has "$OUT" "Tailscale: connected (100.64.0.7)" "pre-flight: a connected Tailscale is named, with its address"
expect_has "$OUT" "The gateway answers at  http://100.64.0.7:4102" "ending: the address is the tailnet one"
expect_has "$OUT" "Nothing else is left to do on this computer." "ending: an empty list says so"
expect_lacks "$OUT" "Open Tailscode, pick this server" "ending: a machine that is ready is not sent to set anything up"

fresh_home
BASE="" ENV_EXTRA="FAKE_DOCTOR=needs-docker" install --no-service
expect_has "$OUT" "Run this on this computer, in this order, because it needs administrator rights:" "ending: hands over the administrator commands"
expect_has "$OUT" "       sudo apt-get install -y docker.io" "ending: the first command, from the program"
expect_has "$OUT" "       sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" "ending: the second command, from the program"
expect_has "$OUT" "Open Tailscode, pick this server and tap Set up voice." "ending: and then Tailscode"

fresh_home
BASE="$SERVER/badsum" ENV_EXTRA="" install --no-service
check "bad checksum: aborts when there is no way to build" test "$RC" -ne 0
expect_has "$OUT" "Building from source instead, because the download did not match its checksum and was thrown away; that takes 5 to 15 minutes" "bad checksum: one sentence says why and how long"
expect_has "$OUT" "https://www.swift.org/install/" "bad checksum: and how to get Swift"
check "bad checksum: nothing was installed" test ! -e "$SHARE/bin/voice-bridge" -a ! -e "$HOME_DIR/.config/voice-bridge.env" -a ! -e "$HOME_DIR/.local/bin/voice-bridge"

fresh_home
shim git 'echo "$*" >>"'"$TMP"'/git.log"; if [ "$1" = clone ]; then exit 1; fi; exit 0'
shim swift 'exit 0'
rm -f "$TMP/git.log"
BASE="$SERVER/badsum" ENV_EXTRA="" install --no-service
check "bad checksum: with a toolchain the source build is what runs" grep -q "clone" "$TMP/git.log"
expect_has "$OUT" "cloning https://github.com/guitaripod/voice-bridge into $SHARE/src/voice-bridge" "bad checksum: and it clones the repo"

fresh_home
shim git 'echo "$*" >>"'"$TMP"'/git.log"; if [ "$1" = clone ]; then mkdir -p "$4"; fi; exit 0'
shim swift 'exit 0'
rm -f "$TMP/git.log"
BASE="$SERVER/badsum" ENV_EXTRA="VOICE_KIT_REPO=https://example.test/kit" install --no-service
check "source build: clones the kit beside the gateway, so ../CodingAgentKit resolves" \
  bash -c "grep -q 'clone --quiet https://github.com/guitaripod/voice-bridge $SHARE/src/voice-bridge' '$TMP/git.log' && grep -q 'clone --quiet https://example.test/kit $SHARE/src/CodingAgentKit' '$TMP/git.log'"

fresh_home
BASE="$SERVER/noasset" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because no prebuilt program has been published for $PLATFORM" "missing asset: falls back and says why"

fresh_home
BASE="$SERVER/nothing-here" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because no prebuilt release has been published yet" "missing release: falls back and says why"

fresh_home
BASE="http://127.0.0.1:$CLOSED_PORT" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because the prebuilt release could not be downloaded" "no network: falls back and says why"

fresh_home
BASE="$SERVER/nostart" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because the prebuilt program does not start on this machine" "a program that will not run here: falls back and says why"
check "a program that will not run here: is not installed" test ! -e "$SHARE/bin/voice-bridge"

fresh_home
shim uname 'case "$1" in -s) echo Linux;; -m) echo mips;; *) exec '"$(command -v uname)"' "$@";; esac'
BASE="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because there is no prebuilt program for Linux on mips" "unsupported platform: falls back and says why"

fresh_home
shim uname 'case "$1" in -s) echo Darwin;; -m) echo arm64;; *) exec '"$(command -v uname)"' "$@";; esac'
BASE="" ENV_EXTRA="" install
check "macOS: exit 3 and nothing is created" test "$RC" -eq 3 -a ! -e "$SHARE" -a ! -e "$HOME_DIR/.local" -a ! -e "$HOME_DIR/.config"
expect_has "$OUT" "a Mac has no NVIDIA GPU, so voice-bridge cannot run on this computer" "macOS: says why in plain words"

fresh_home
BASE="" ENV_EXTRA="" install --no-service --from-source
expect_has "$OUT" "Building from source, as you asked; that takes 5 to 15 minutes" "--from-source: says so and how long"
expect_lacks "$OUT" "downloading" "--from-source: downloads nothing"

fresh_home
BASE="" ENV_EXTRA="" install --nonsense
check "an option it does not know is refused, not ignored" test "$RC" -eq 2
expect_has "$OUT" "unknown option: --nonsense" "an unknown option: says which"

fresh_home
BASE="" ENV_EXTRA="" install --no-service
printf '# mine\n' >>"$HOME_DIR/.config/voice-bridge.env"
mkdir -p "$HOME_DIR/.config/systemd/user"
printf '[Service]\n' >"$HOME_DIR/.config/systemd/user/voice-bridge.service"
recording_service_shims
before_unit="$(cksum <"$HOME_DIR/.config/systemd/user/voice-bridge.service")"
before_env="$(cksum <"$HOME_DIR/.config/voice-bridge.env")"
before_time="$(stat_mtime "$SHARE/bin/voice-bridge")"
sleep 1
BASE="" ENV_EXTRA="FAKE_DOCTOR=nogpu" install --update
check "--update: succeeds, even on a machine whose check would now say no GPU" test "$RC" -eq 0
check "--update: the new program is stamped as newer than the old" test "$(stat_mtime "$SHARE/bin/voice-bridge")" -gt "$before_time"
check "--update: the env file is untouched" test "$(cksum <"$HOME_DIR/.config/voice-bridge.env")" = "$before_env"
check "--update: the unit is untouched" test "$(cksum <"$HOME_DIR/.config/systemd/user/voice-bridge.service")" = "$before_unit"
check "--update: no service manager is called, so a running gateway is never restarted" test ! -s "$SERVICE_LOG"
check "--update: the staged installer is refreshed" cmp -s "$SHARE/install.sh" "$ROOT/install.sh"
expect_has "$OUT" "installed voice-bridge 9.9.9" "--update: says what it installed"
expect_lacks "$OUT" "What is left to do" "--update: no install report"

before_program="$(cksum <"$SHARE/bin/voice-bridge")"
BASE="$SERVER/badsum" ENV_EXTRA="" install --update
check "failed update: exits non-zero" test "$RC" -ne 0
expect_has "$OUT" "error: the download did not match its checksum and was thrown away" "failed update: the last line is a sentence for a person"
check "failed update: the installed program is untouched" test "$(cksum <"$SHARE/bin/voice-bridge")" = "$before_program"
expect_lacks "$OUT" "Building from source" "failed update: a prebuilt install does not turn into a source build behind the person's back"

fresh_home
mkdir -p "$SHARE/src/voice-bridge/.git"
shim git 'case "$1 $2" in "-C "*) shift 2;; esac; case "$1" in status) exit 0;; fetch) exit 1;; esac; exit 0'
shim swift 'exit 0'
BASE="http://127.0.0.1:$CLOSED_PORT" ENV_EXTRA="" install --update
expect_lacks "$OUT" "downloading" "update of a source install stays a source update: no download is tried"
expect_has "$OUT" "could not reach" "update of a source install: it is the source that fails"

fresh_home
shim tailscale 'cat >/dev/null; case "$1" in status) exit 0;; ip) echo 100.64.0.9;; esac'
PIPED=1 BASE="" ENV_EXTRA="VOICE_TAILSCALE=$SHIMS/tailscale FAKE_DOCTOR=ready" install --no-service
check "piped through bash like the one-liner: tools that read stdin cannot eat the script" test "$RC" -eq 0 -a -x "$SHARE/bin/voice-bridge"
expect_has "$OUT" "The gateway answers at  http://100.64.0.9:4102" "piped through bash like the one-liner: reaches the ending"

REAL="$ROOT/.build/debug/voice-bridge"
REAL_LINE=""
[ ! -x "$REAL" ] || REAL_LINE="$(timeout 10 "$REAL" --version </dev/null 2>/dev/null | head -1)"
case "$REAL_LINE" in
  "voice-bridge $VERSION") ;;
  *) REAL="" ;;
esac
if [ -n "$REAL" ]; then
  REAL_VERSION="$VERSION"
  mkdir -p "$WWW/real"
  "$ROOT/scripts/package-release.sh" --binary "$REAL" --version "$REAL_VERSION" --out "$WWW/real" >"$TMP/package-real.log" 2>&1
  printf '%s\n' "$REAL_VERSION" >"$WWW/real/latest.txt"
  NIM_URL="ws://127.0.0.1:$CLOSED_PORT/v1/realtime"
  real_tools() {
    shim nvidia-smi 'case "$1" in
  --query-gpu*) echo "NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 97887, 1200";;
  --query-compute-apps*) ;;
esac'
    shim docker 'case "$1" in
  version) echo 29.8.2;;
  image) echo "Error: No such image" >&2; exit 1;;
  ps) ;;
esac'
    shim nvidia-ctk 'echo nvidia.com/gpu=0'
  }

  fresh_home
  real_tools
  BASE="$SERVER/real" ENV_EXTRA="VOICE_NIM_URL=$NIM_URL" install --no-service
  check "the real program: installs from its own release archive" test "$RC" -eq 0 -a -x "$SHARE/bin/voice-bridge"
  check "the real program: reports the version the changelog heads with" \
    test "$("$HOME_DIR/.local/bin/voice-bridge" --version)" = "voice-bridge $VERSION"
  expect_has "$OUT" "This machine has an NVIDIA RTX PRO 6000 Blackwell Workstation Edition with 96 GB: voice calls can run here." "the real program: the verdict, from its own doctor"
  expect_has "$OUT" "Voice model: not downloaded yet (47 GB, about 15 minutes). Tailscode will do this for you." "the real program: the Tailscode note"
  expect_has "$OUT" "Open Tailscode, pick this server and tap Set up voice." "the real program: the last chore"
  expect_lacks "$OUT" "administrator rights" "the real program: no administrator command when docker and CDI are there"

  fresh_home
  real_tools
  shim nvidia-smi 'echo "NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver." >&2; exit 9'
  BASE="$SERVER/real" ENV_EXTRA="VOICE_NIM_URL=$NIM_URL" install --no-service
  check "the real program without a GPU: exit 3 and nothing installed" test "$RC" -eq 3 -a ! -e "$SHARE/bin" -a ! -e "$HOME_DIR/.config"
  expect_has "$OUT" "No NVIDIA GPU with 64 GB: voice calls cannot run on this machine." "the real program without a GPU: the honest verdict"

  fresh_home
  real_tools
  shim nvidia-smi 'case "$1" in
  --query-gpu*) echo "NVIDIA L40S, 46068, 100";;
  --query-compute-apps*) ;;
esac'
  BASE="$SERVER/real" ENV_EXTRA="VOICE_NIM_URL=$NIM_URL" install --no-service
  check "the real program with a small card: exit 3" test "$RC" -eq 3
  expect_has "$OUT" "The card here, an NVIDIA L40S, has 45 GB." "the real program with a small card: names it"

  fresh_home
  real_tools
  rm -f "$SHIMS/docker" "$SHIMS/nvidia-ctk"
  BASE="$SERVER/real" ENV_EXTRA="VOICE_NIM_URL=$NIM_URL" install --no-service
  expect_has "$OUT" "Run this on this computer, in this order, because it needs administrator rights:" "the real program without docker: hands over the command"
  expect_has "$OUT" "Run: " "the real program without docker: the report shows the command beside the row"
else
  printf 'skip  the real program (no current build in %s; run swift build first)\n' "$ROOT/.build/debug"
fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
