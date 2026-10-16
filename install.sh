#!/usr/bin/env bash
#
# voice-bridge installer and updater.
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/voice-bridge/master/install.sh | bash
#
# Downloads the prebuilt release for this machine into ~/.local/share/voice-bridge/bin, links it from
# ~/.local/bin, writes ~/.config/voice-bridge.env when there is none, and registers the voice-bridge
# user service so the gateway comes back after a reboot. No Swift and no git are needed for that. Only
# when there is no prebuilt release for this machine, the download fails or does not check out, or
# --from-source is given, does it clone the repo into ~/.local/share/voice-bridge/src and build it.
#
# Voice calls run an NVIDIA model, so the installer asks the program it just downloaded
# (voice-bridge doctor) whether this machine can run it before it installs anything. A machine that
# cannot gets that answer and nothing else; --force installs the gateway anyway.
#
# Everything else voice needs (Docker, the GPU for containers, the 44 GB model, the 22 GB engine image)
# is set up from Tailscode: the installer only tells you what is left. It never restarts a gateway
# that is running; `voice-bridge update` does that when no call is going.
#
# Re-run it any time to update. --update replaces the program and touches nothing else (it is what
# `voice-bridge update` runs). --no-service installs everything except the service.

# shellcheck disable=SC1090
set -euo pipefail

REPO="https://github.com/guitaripod/voice-bridge"
KIT_REPO="${VOICE_KIT_REPO:-https://github.com/guitaripod/CodingAgentKit}"
RELEASE_BASE="${VOICE_RELEASE_BASE:-$REPO/releases/latest/download}"
RELEASE_BASE="${RELEASE_BASE%/}"
SHARE="${VOICE_SHARE_DIR:-$HOME/.local/share/voice-bridge}"
SRC="${VOICE_SRC:-$SHARE/src}"
BIN_DIR="$SHARE/bin"
LINK_DIR="$HOME/.local/bin"
LINK="$LINK_DIR/voice-bridge"
ENV_FILE="${VOICE_ENV_FILE:-$HOME/.config/voice-bridge.env}"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="${VOICE_UNIT:-voice-bridge.service}"
EXTERNAL_UNIT="nemotron-voicechat.service"
STAGED="$SHARE/install.sh"
LOG="$SHARE/install.log"
PORT=""
MODE="install"
NO_SERVICE=""
FROM_SOURCE=""
FORCE=""
for argument in "$@"; do
  case "$argument" in
    --update) MODE="update" ;;
    --no-service) NO_SERVICE="1" ;;
    --from-source) FROM_SOURCE="1" ;;
    --force) FORCE="1" ;;
    *)
      printf 'unknown option: %s\nusage: install.sh [--update] [--no-service] [--from-source] [--force]\n' "$argument" >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [ "$(uname -s)" = "Darwin" ]; then
  say "Voice calls run an NVIDIA model, and a Mac has no NVIDIA GPU, so voice-bridge cannot run on this computer."
  say "Install it on a Linux computer with an NVIDIA GPU that has 80 GB of memory; Tailscode on this Mac can still make calls through it."
  exit 3
fi

mkdir -p "$SHARE"

WORK=""
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

LEFT=()

add_left() { LEFT+=("$*"); }

# Runs a command and gives up on it after a number of seconds. Everything the installer asks of
# another program (tailscale, the freshly downloaded binary, the service manager) must not be able to
# hold the install hostage. The kill cannot be argued with, because a shell started with SIGTERM
# ignored passes that on to every child.
bounded() {
  local seconds="$1" pid timer status=0
  shift
  "$@" </dev/null &
  pid=$!
  ( sleep "$seconds"; kill -KILL "$pid" ) >/dev/null 2>&1 &
  timer=$!
  wait "$pid" 2>/dev/null || status=$?
  kill -KILL "$timer" >/dev/null 2>&1 || true
  wait "$timer" 2>/dev/null || true
  return "$status"
}

PROGRAM="$BIN_DIR/voice-bridge"
DELIVERY="source"

# Which of the two ways of getting a program this run will try first. A machine that already has a
# checkout keeps building from it, so an update does not swap a prebuilt program in beside a source
# tree that would then go stale.
choose_delivery() {
  if [ -n "$FROM_SOURCE" ]; then
    say "Building from source, as you asked; that takes 5 to 15 minutes and needs Swift and git."
  elif [ -d "$SRC/voice-bridge/.git" ]; then
    [ "$MODE" = "update" ] ||
      say "keeping the source build in $SRC — remove that folder to switch to the prebuilt program"
  else
    DELIVERY="binary"
  fi
  if [ "$DELIVERY" = "source" ]; then
    PROGRAM="$SRC/voice-bridge/.build/release/voice-bridge"
  fi
}

# Falls back to the source build, with the one sentence that says why and what it costs.
fall_back_to_source() {
  DELIVERY="source"
  PROGRAM="$SRC/voice-bridge/.build/release/voice-bridge"
  say "Building from source instead, because $1; that takes 5 to 15 minutes and needs Swift and git."
}

detect_platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) printf 'linux-x86_64' ;;
    Linux-aarch64|Linux-arm64) printf 'linux-aarch64' ;;
  esac
}

# One download, quiet, retried on the failures a retry can cure. The exit status tells a missing
# file (22) from a network that is not there.
download() {
  curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 900 \
    -o "$2" "$1" 2>>"$LOG"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads the latest release for this machine and proves it: the checksum matches and the program
# starts here. Leaves the verified program in $WORK/voice-bridge (and the installer that shipped with
# it in $WORK/install.sh when the archive has one) and the version in $VERSION, or the reason it
# could not in $FETCH_REASON.
VERSION=""
FETCH_REASON=""
fetch_release() {
  local platform asset expected status=0
  command -v curl >/dev/null 2>&1 || { FETCH_REASON="curl is not installed"; return 1; }
  platform="$(detect_platform)"
  [ -n "$platform" ] || {
    FETCH_REASON="there is no prebuilt program for $(uname -s) on $(uname -m)"
    return 1
  }
  find "$SHARE" -maxdepth 1 -name '.download.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  WORK="$(mktemp -d "$SHARE/.download.XXXXXX")"

  say "downloading the latest voice-bridge for $platform"
  download "$RELEASE_BASE/latest.txt" "$WORK/latest.txt" || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 22 ] && FETCH_REASON="no prebuilt release has been published yet" ||
      FETCH_REASON="the prebuilt release could not be downloaded from $RELEASE_BASE"
    return 1
  fi
  VERSION="$(tr -d '[:space:]' <"$WORK/latest.txt")"
  case "$VERSION" in
    ''|*[!0-9.]*|.*|*.) FETCH_REASON="the release list at $RELEASE_BASE is not readable"; return 1 ;;
  esac

  asset="voice-bridge-$VERSION-$platform.tar.gz"
  download "$RELEASE_BASE/$asset" "$WORK/$asset" || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 22 ] && FETCH_REASON="no prebuilt program has been published for $platform" ||
      FETCH_REASON="the prebuilt program could not be downloaded from $RELEASE_BASE"
    return 1
  fi
  download "$RELEASE_BASE/$asset.sha256" "$WORK/$asset.sha256" || {
    FETCH_REASON="the prebuilt program came without its checksum"
    return 1
  }
  expected="$(awk 'NR==1 {print $1}' "$WORK/$asset.sha256")"
  [ "$expected" = "$(checksum "$WORK/$asset")" ] || {
    FETCH_REASON="the download did not match its checksum and was thrown away"
    return 1
  }

  tar -xzf "$WORK/$asset" -C "$WORK" voice-bridge 2>>"$LOG" || {
    FETCH_REASON="the download could not be unpacked"
    return 1
  }
  tar -xzf "$WORK/$asset" -C "$WORK" install.sh 2>>"$LOG" || true
  chmod 755 "$WORK/voice-bridge"
  [ "$(bounded 15 "$WORK/voice-bridge" --version 2>/dev/null || true)" = "voice-bridge $VERSION" ] || {
    FETCH_REASON="the prebuilt program does not start on this machine"
    return 1
  }
}

# Puts the verified program where the link points. The rename is what keeps a running gateway safe:
# its old file stays whole until it exits, and a crash here leaves the old program.
install_release() {
  mkdir -p "$BIN_DIR"
  touch "$WORK/voice-bridge"
  mv -f "$WORK/voice-bridge" "$BIN_DIR/.voice-bridge.new"
  mv -f "$BIN_DIR/.voice-bridge.new" "$PROGRAM"
}

# Keeps the installer that shipped with this release, so `voice-bridge update` can run it. A source
# build has its own copy in the checkout.
stage_installer() {
  if [ "$DELIVERY" = "binary" ] && [ -f "$WORK/install.sh" ]; then
    cp "$WORK/install.sh" "$STAGED.new"
  elif [ "$DELIVERY" = "source" ] && [ -f "$SRC/voice-bridge/install.sh" ]; then
    cp "$SRC/voice-bridge/install.sh" "$STAGED.new"
  else
    return 0
  fi
  chmod 755 "$STAGED.new"
  mv -f "$STAGED.new" "$STAGED"
}

# Links the program from ~/.local/bin, which is where the service starts it from.
link_program() {
  mkdir -p "$LINK_DIR"
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    say "  replacing the copy of voice-bridge at $LINK with a link to the installed program"
  fi
  ln -sfn "$PROGRAM" "$LINK"
}

require_toolchain() {
  if ! command -v swift >/dev/null 2>&1; then
    for candidate in "$HOME/.local/share/swiftly/bin" /usr/local/swift/usr/bin /opt/swift/usr/bin; do
      [ -x "$candidate/swift" ] && PATH="$candidate:$PATH" && export PATH && break
    done
  fi
  if ! command -v swift >/dev/null 2>&1; then
    command -v git >/dev/null 2>&1 &&
      fail "building from source needs Swift, which is not installed — get it from https://www.swift.org/install/ and run this again"
    fail "building from source needs Swift and git, which are not installed — get Swift from https://www.swift.org/install/ and git from your package manager, then run this again"
  fi
  command -v git >/dev/null 2>&1 ||
    fail "building from source needs git, which is not installed — install it with your package manager and run this again"
}

# Voice-bridge builds against CodingAgentKit as a sibling folder, so a checkout holds both.
sync_checkout() {
  local url="$1" folder="$2"
  if [ -d "$folder/.git" ]; then
    say "updating $folder"
    [ -z "$(git -C "$folder" status --porcelain)" ] ||
      fail "$folder has uncommitted changes; commit, stash, or remove them first"
    git -C "$folder" fetch --quiet --tags origin </dev/null || fail "could not reach $url"
    local branch
    branch="$(git -C "$folder" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/master)"
    git -C "$folder" merge --ff-only "$branch" >>"$LOG" 2>&1 ||
      fail "could not fast-forward $folder to $branch"
  else
    say "cloning $url into $folder"
    mkdir -p "$(dirname "$folder")"
    git clone --quiet "$url" "$folder" </dev/null || fail "clone of $url failed"
  fi
}

fetch_source() {
  sync_checkout "$REPO" "$SRC/voice-bridge"
  sync_checkout "$KIT_REPO" "$SRC/CodingAgentKit"
}

# A build failure is read by a person, so it is worth saying what actually went wrong rather than
# handing over the last twelve lines of a linker's opinion.
build_reason() {
  local tail
  tail="$(tail -c 4000 "$LOG" 2>/dev/null || true)"
  case "$tail" in
    *"No space left on device"*) printf 'the disk filled up during the build' ;;
    *"Killed"*|*"signal 9"*) printf 'the build was killed — this machine ran out of memory' ;;
    *"module compiled with Swift"*|*"module file format"*)
      printf 'the checkout needs a different Swift than the one installed' ;;
    *) printf 'build failed — see %s' "$LOG" ;;
  esac
}

# Enough room to build. A disk that fills mid-link reports itself as an unreadable linker error, and
# the number is the one thing that makes it actionable.
check_space() {
  local free
  mkdir -p "$SRC"
  free="$(df -Pk "$SRC" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
  [ -n "$free" ] || return 0
  [ "$free" -ge 3000000 ] ||
    fail "only $(( free / 1024 )) MB free where the checkout lives; the build needs about 3 GB"
}

build() {
  check_space
  say "building (this takes a few minutes the first time)"
  if ! ( cd "$SRC/voice-bridge" && swift build -c release --build-system native </dev/null ) >>"$LOG" 2>&1; then
    say "build failed; cleaning and trying once more"
    ( cd "$SRC/voice-bridge" && swift package clean </dev/null ) >>"$LOG" 2>&1 || true
    ( cd "$SRC/voice-bridge" && swift build -c release --build-system native </dev/null ) >>"$LOG" 2>&1 ||
      fail "$(build_reason)"
  fi
}

# The value a name has in the env file, which is what the service will use whatever the environment
# of this run says. The file is systemd's format, not a shell's, so it is read as text.
config_value() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*\\(export[[:space:]]\\{1,\\}\\)\\{0,1\\}$1=//p" "$ENV_FILE" | tail -1 |
    sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/"
}

# Settings are the person's to keep: an existing file is never touched, however old it is.
write_env() {
  if [ -f "$ENV_FILE" ]; then
    say "  kept your settings in $ENV_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$ENV_FILE")"
  cat >"$ENV_FILE" <<'EOF'
# voice-bridge settings, read by the service. Edit, then restart it:  systemctl --user restart voice-bridge
# Every setting is listed in the README (VOICE_* names). The defaults need none of these.
#
# The port the gateway listens on, on this computer and on its tailnet address.
# VOICE_PORT=4102
# When set, Tailscode must send this password; without it anything on your tailnet may call.
# VOICE_PASSWORD=
# Where the voice model is downloaded and looked for.
# VOICE_MODEL_DIR=
# NVIDIA's key for downloading the model (or run  ngc config set  once).
# NGC_API_KEY=
EOF
  chmod 600 "$ENV_FILE"
  say "  wrote $ENV_FILE with the defaults commented out"
}

write_unit() {
  local target="$UNIT_DIR/$UNIT"
  if [ -f "$target" ] && [ -z "${VOICE_FORCE_SERVICE:-}" ]; then
    say "  kept the existing $UNIT"
    return 0
  fi
  cat >"$target" <<'EOF'
[Unit]
Description=voice-bridge, the gateway between Tailscode calls and the NemotronLabs VoiceChat NIM
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/voice-bridge
EnvironmentFile=-%h/.config/voice-bridge.env
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  say "  installed $UNIT"
}

# The unit for running the voice container yourself. It is copied so it is there if wanted and never
# enabled: the gateway starts the container for a call by itself.
write_external_unit() {
  local target="$UNIT_DIR/$EXTERNAL_UNIT" docker model
  [ ! -f "$target" ] || return 0
  docker="$(command -v docker 2>/dev/null || echo /usr/bin/docker)"
  model="$(config_value VOICE_MODEL_DIR)"
  model="${model:-%h/.local/share/voice-bridge/model}"
  cat >"$target" <<EOF
[Unit]
Description=NemotronLabs VoiceChat 11B NIM on port 9000 (optional, only for VOICE_ENGINE=external)
After=docker.service network-online.target

[Service]
Type=simple
ExecStartPre=-$docker rm -f nemotron-labs-voicechat
ExecStart=$docker run --rm --name=nemotron-labs-voicechat --device nvidia.com/gpu=0 --shm-size=8GB -e NIM_HTTP_API_PORT=9000 -p 127.0.0.1:9000:9000 -v $model/nemotron-labs-voicechat_v1.0.0:/data/models --entrypoint /s2s/run_s2s_server.sh nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest
ExecStop=$docker stop nemotron-labs-voicechat
TimeoutStartSec=600
TimeoutStopSec=60
Restart=no
EOF
  say "  copied $EXTERNAL_UNIT (not enabled; only for running the voice engine yourself)"
}

SERVICE_WAS_RUNNING=""
SERVICE_STARTED=""

# Registers and starts the service. A running gateway is left running: `enable --now` starts one
# that is stopped and does nothing to one that is not, so a call in progress is never cut.
install_service() {
  mkdir -p "$UNIT_DIR"
  write_unit
  write_external_unit
  if ! command -v systemctl >/dev/null 2>&1 || ! bounded 20 systemctl --user daemon-reload >>"$LOG" 2>&1; then
    say "  no user service manager answered here, so no service was started"
    add_left "Start the gateway yourself, or from your own service manager:  $LINK"
    return 0
  fi
  loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1 || true
  bounded 20 systemctl --user is-active --quiet "$UNIT" && SERVICE_WAS_RUNNING="1"
  bounded 30 systemctl --user enable --now "$UNIT" >>"$LOG" 2>&1 ||
    fail "could not start $UNIT — see  journalctl --user -u $UNIT"
  if [ -n "$SERVICE_WAS_RUNNING" ]; then
    say "  $UNIT was already running and was left running"
  else
    say "  started $UNIT; it comes back after a reboot"
    SERVICE_STARTED="1"
  fi
}

TAILSCALE=""
find_tailscale() {
  local candidate
  if [ -n "${VOICE_TAILSCALE:-}" ]; then
    [ -x "$VOICE_TAILSCALE" ] && { TAILSCALE="$VOICE_TAILSCALE"; return 0; }
    return 1
  fi
  for candidate in "$(command -v tailscale 2>/dev/null || true)" /usr/bin/tailscale /usr/local/bin/tailscale; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { TAILSCALE="$candidate"; return 0; }
  done
  return 1
}

TAILNET_ADDRESS=""

# The gateway listens on this computer and on its tailnet address, which it reads once when it
# starts. Without Tailscale it still works on this computer, but the phone cannot reach it, and a
# Tailscale that comes up later is not noticed until the gateway restarts.
preflight_tailscale() {
  local output="" status=0 when="Until then Tailscode on your phone cannot reach the gateway, which listens on this computer only. Once it is up, restart the gateway so it picks up the address:  systemctl --user restart $UNIT"
  if ! find_tailscale; then
    say "  Tailscale: not installed"
    add_left "Install Tailscale on this computer and on your phone (https://tailscale.com/download) and sign in to both with the same account. $when"
    return 0
  fi
  output="$(bounded 10 "$TAILSCALE" status 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    TAILNET_ADDRESS="$(bounded 10 "$TAILSCALE" ip -4 2>/dev/null | head -1 || true)"
    say "  Tailscale: connected${TAILNET_ADDRESS:+ ($TAILNET_ADDRESS)}"
    return 0
  fi
  case "$output" in
    *"Logged out"*|*"NeedsLogin"*|*"Log in at"*)
      say "  Tailscale: installed, but not signed in"
      add_left "Sign in to Tailscale on this computer: run  sudo tailscale up  (or open the Tailscale app) and finish the sign-in. $when" ;;
    *"stopped"*)
      say "  Tailscale: installed, but turned off"
      add_left "Turn Tailscale on: run  sudo tailscale up  (or switch it on in the Tailscale app). $when" ;;
    *)
      say "  Tailscale: installed, but not running"
      add_left "Start Tailscale: run  sudo systemctl enable --now tailscaled  and then  sudo tailscale up. $when" ;;
  esac
}

# Voice needs an NVIDIA card with 80 GB. A source build takes a quarter of an hour, so a machine that
# has no nvidia-smi at all is told before it is made to wait; the program's own check, which also
# reads the card's size, runs once there is a program.
precheck_source_hardware() {
  [ -z "$FORCE" ] || return 0
  command -v nvidia-smi >/dev/null 2>&1 && return 0
  say ""
  say "No NVIDIA GPU with 80 GB: voice calls cannot run on this machine. nvidia-smi is not installed."
  say "Nothing was installed. If you want the gateway here anyway, run this again with --force."
  exit 3
}

# Asks the program whether this machine can run voice calls, before anything is installed. Exit 3
# is its answer for a machine that cannot.
DOCTOR_FAILED=""
check_hardware() {
  local candidate="$1" output status=0
  output="$(bounded 90 "$candidate" doctor 2>&1)" || status=$?
  [ "$status" -eq 3 ] || return 0
  say ""
  say "$output"
  if [ -z "$FORCE" ]; then
    say ""
    say "Nothing was installed. Voice calls need the NVIDIA GPU, so the gateway would have nothing to run."
    say "If you want it here anyway, run this again with --force."
    exit 3
  fi
  DOCTOR_FAILED="1"
  add_left "This computer cannot run voice calls (see above); the gateway was installed because of --force."
}

# The gateway is up when it answers its own health route.
wait_for_health() {
  local password attempt=0 code auth=()
  command -v curl >/dev/null 2>&1 || return 0
  password="$(config_value VOICE_PASSWORD)"
  [ -z "$password" ] || auth=(-H "Authorization: Bearer $password")
  while [ "$attempt" -lt "${VOICE_HEALTH_ATTEMPTS:-10}" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${auth[@]}" "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    [ "$code" = 200 ] && return 0
    attempt=$(( attempt + 1 ))
    sleep 1
  done
  return 1
}

print_left() {
  local number=1 item
  if [ "${#LEFT[@]}" -eq 0 ]; then
    printf '\nNothing else is left to do on this computer.\n'
    return 0
  fi
  printf '\nWhat is left to do:\n'
  for item in "${LEFT[@]}"; do
    printf '  %d. %s\n' "$number" "$item"
    number=$(( number + 1 ))
  done
}

# The commands that need a person with administrator rights, from the program's own check, one per
# line. The program knows this machine's distribution; the installer does not guess.
sudo_commands() {
  bounded 90 "$PROGRAM" doctor --commands 2>/dev/null || true
}

# Runs the program's check on the installed gateway and turns what it finds into the closing list.
final_check() {
  local commands ready="" report
  report="$(bounded 90 "$PROGRAM" doctor 2>&1 || true)"
  printf '\nWhat voice needs on this computer:\n\n%s\n' "$report"
  [ -z "$DOCTOR_FAILED" ] || return 0
  commands="$(sudo_commands)"
  bounded 90 "$PROGRAM" doctor --json 2>/dev/null | grep -Fq '"ready":true' && ready="1"
  if [ -n "$commands" ]; then
    add_left "Run this on this computer, in this order, because it needs administrator rights:
$(printf '%s\n' "$commands" | sed 's/^/       /')"
  fi
  if [ -n "$commands" ] || [ -z "$ready" ]; then
    add_left "Open Tailscode, pick this server and tap Set up voice. It downloads the voice model (47 GB) and the engine image (23 GB) and checks the rest."
  fi
}

print_address() {
  local address="${TAILNET_ADDRESS:-$(uname -n)}"
  printf '\nThe gateway answers at  http://%s:%s\n' "$address" "$PORT"
}

report() {
  PORT="$(config_value VOICE_PORT)"
  PORT="${PORT:-4102}"
  if [ -n "$NO_SERVICE" ]; then
    printf '\nvoice-bridge is installed but not started. Start it with:  %s\n' "$LINK"
  elif [ -n "$SERVICE_STARTED" ] && wait_for_health; then
    printf '\nvoice-bridge is running.\n'
  elif [ -n "$SERVICE_WAS_RUNNING" ]; then
    printf '\nvoice-bridge was already running and keeps running the program it started with.\n'
    add_left "Restart the gateway into the new program when no call is going:  voice-bridge update"
  else
    printf '\nvoice-bridge is installed, but it is not answering on port %s yet.\n' "$PORT"
    add_left "Find out why the gateway did not start:  journalctl --user -u $UNIT"
  fi
  final_check
  print_left
  print_address
  printf '\nSettings  %s\n' "$ENV_FILE"
  if [ "$DELIVERY" = "source" ]; then
    printf 'Source    %s\n' "$SRC"
  else
    printf 'Program   %s\n' "$PROGRAM"
  fi
  printf 'Update    voice-bridge update   (or run the install command again)\n'
}

obtain_program() {
  if [ "$DELIVERY" = "binary" ]; then
    if [ "$MODE" = "update" ]; then
      fetch_release || fail "$FETCH_REASON"
    else
      fetch_release || fall_back_to_source "$FETCH_REASON"
    fi
  fi
  if [ "$DELIVERY" = "source" ]; then
    [ "$MODE" = "update" ] || precheck_source_hardware
    require_toolchain
    fetch_source
    build
  fi
}

CANDIDATE=""
candidate_program() {
  if [ "$DELIVERY" = "binary" ]; then CANDIDATE="$WORK/voice-bridge"; else CANDIDATE="$PROGRAM"; fi
}

install_program() {
  if [ "$DELIVERY" = "binary" ]; then
    install_release
    say "  installed voice-bridge $VERSION to $PROGRAM"
  else
    say "  built voice-bridge in $PROGRAM"
  fi
  stage_installer
  link_program
}

choose_delivery

if [ "$MODE" = "update" ]; then
  obtain_program
  install_program
  exit 0
fi

say "Checking this computer:"
preflight_tailscale
say ""
obtain_program
candidate_program
check_hardware "$CANDIDATE"
say ""
say "Installing:"
install_program
write_env
if [ -z "$NO_SERVICE" ]; then
  install_service
fi
report
