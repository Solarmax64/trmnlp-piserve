#!/usr/bin/env bash
set -Eeuo pipefail

# keep terminal sane
ORIG_STTY="$(stty -g 2>/dev/null || true)"
restore_tty(){ command -v stty >/dev/null 2>&1 && [[ -n "${ORIG_STTY:-}" ]] && stty "$ORIG_STTY" || true; }
trap restore_tty EXIT HUP INT TERM

# ---- guard: don't run whole script as root ----
if [[ $EUID -eq 0 ]]; then
  echo "[✗] Do not run this script as root. Run as your user (e.g., pi)."
  exit 1
fi

# ------------ Config (defaults) ------------
BASE_DIR="/home/pi/syncthing/trmnl-plugins"
STATE_DIR="${HOME}/.config/trmnlp-piserve"
SECRETS_FILE="${STATE_DIR}/secrets.env"
SETTINGS_FILE="${STATE_DIR}/settings.env"
PID_DIR="${STATE_DIR}/pids"
LOG_DIR="${STATE_DIR}/logs"
PROXY_PID_DIR="${STATE_DIR}/proxy-pids"
FF_PROFILE_DIR="${STATE_DIR}/ff-profile"

ENGINE="${ENGINE:-gem}"             # gem|repo
REPO_DIR="${REPO_DIR:-$HOME/trmnlp}"

SHOW_BACKUPS="${SHOW_BACKUPS:-0}"
PRINT_ONLY="${PRINT_ONLY:-0}"

BIND_PORT="${BIND_PORT:-4567}"

ENABLE_PROXY="${ENABLE_PROXY:-1}"
SOCAT_BIN="${SOCAT_BIN:-/usr/bin/socat}"

# Firefox Nightly settings
FFN_DIR="${FFN_DIR:-/opt/firefox-nightly}"               # for tarball fallback
FFN_BIN_LINK="${FFN_BIN_LINK:-/usr/local/bin/firefox-nightly}"
FFN_LANG="${FFN_LANG:-en-US}"
FFN_URL="${FFN_URL:-}"                                   # optional custom URL override

# Default if we must guess; we'll auto-detect dynamically too
TRMNL_PREVIEW_FIREFOX_DEFAULT="${TRMNL_PREVIEW_FIREFOX_DEFAULT:-/usr/local/bin/firefox-nightly}"

# Dialog command (whiptail preferred, dialog fallback)
DIALOG_CMD=""

mkdir -p "${STATE_DIR}" "${PID_DIR}" "${LOG_DIR}" "${PROXY_PID_DIR}" "${FF_PROFILE_DIR}"

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
note(){ printf "[*] %s\n" "$*"; }
warn(){ printf "\033[33m[!] %s\033[0m\n" "$*"; }
err(){  printf "\033[31m[✗] %s\033[0m\n" "$*" >&2; }
die(){  err "$*"; exit 1; }
trim(){ local s="$*"; s="${s//$'\r'/}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
trunc(){ local max="${1:-40}" s="${2:-}"; if (( ${#s} > max )); then printf '%s..' "${s:0:$((max-2))}"; else printf '%s' "$s"; fi; }
ts(){ date +%Y%m%d-%H%M%S; }
term_cols(){ tput cols 2>/dev/null || echo 80; }
term_rows(){ tput lines 2>/dev/null || echo 24; }
dlg_w(){ local want="${1:-70}" tc; tc="$(term_cols)"; (( tc - 4 < want )) && want=$((tc - 4)); (( want < 40 )) && want=40; echo "$want"; }
dlg_h(){ local want="${1:-22}" tr; tr="$(term_rows)"; (( tr - 2 < want )) && want=$((tr - 2)); (( want < 12 )) && want=12; echo "$want"; }

run(){ if [[ "${PRINT_ONLY}" == "1" ]]; then printf '$ '; printf "%q " "$@"; echo; else "$@"; fi; }

ensure_base_dir(){ [[ -d "${BASE_DIR}" ]] || { note "Creating ${BASE_DIR}"; mkdir -p "${BASE_DIR}"; }; }
ensure_secrets(){ mkdir -p "${STATE_DIR}"; [[ -f "${SECRETS_FILE}" ]] || { umask 077; : > "${SECRETS_FILE}"; }; source "${SECRETS_FILE}" 2>/dev/null || true; }

# ------------ Settings persistence ------------
save_settings(){
  ( umask 077; cat > "${SETTINGS_FILE}" <<EOF
BASE_DIR=$(printf '%q' "$BASE_DIR")
BIND_PORT=$(printf '%q' "$BIND_PORT")
ENABLE_PROXY=$(printf '%q' "$ENABLE_PROXY")
SHOW_BACKUPS=$(printf '%q' "$SHOW_BACKUPS")
ENGINE=$(printf '%q' "$ENGINE")
REPO_DIR=$(printf '%q' "$REPO_DIR")
FFN_LANG=$(printf '%q' "$FFN_LANG")
FFN_URL=$(printf '%q' "$FFN_URL")
EOF
  )
}

load_settings(){
  [[ -f "${SETTINGS_FILE}" ]] || return 0
  source "${SETTINGS_FILE}" 2>/dev/null || true
}

load_settings

# ------------ Dialog / whiptail helpers ------------
# Set TRMNLP_TUI=0 to force plain text menus even if whiptail is available
TRMNLP_TUI="${TRMNLP_TUI:-1}"

detect_dialog(){
  [[ "${TRMNLP_TUI}" == "1" ]] || return 0
  local cmd=""
  if command -v whiptail >/dev/null 2>&1; then
    cmd="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    cmd="dialog"
  else
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
    return 0
  fi
  local rows cols
  rows="$(tput lines 2>/dev/null || echo 0)"
  cols="$(tput cols 2>/dev/null || echo 0)"
  if (( rows < 20 || cols < 60 )); then
    return 0
  fi
  DIALOG_CMD="$cmd"
}

ensure_dialog(){
  detect_dialog
  [[ -n "$DIALOG_CMD" ]] && return 0
  if [[ "${TRMNLP_TUI}" != "1" ]]; then
    return 1
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 1
  fi
  echo ""
  read -r -p "whiptail/dialog not found. Install whiptail for TUI menus? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    apt_install whiptail || apt_install dialog || true
    detect_dialog
  fi
  if [[ -z "$DIALOG_CMD" ]]; then
    warn "Using plain text menus."
    return 1
  fi
  return 0
}

dialog_menu(){
  local title="$1" text="$2" height="$3" width="$4" menu_height="$5"
  shift 5
  local rc=0 result=""
  result="$($DIALOG_CMD --title "$title" --menu "$text" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3)" || rc=$?
  if (( rc == 255 )); then
    echo ""
    return 0
  fi
  printf '%s' "$result"
}

dialog_inputbox(){
  local title="$1" text="$2" height="${3:-8}" width="${4:-60}" init="${5:-}"
  $DIALOG_CMD --title "$title" --inputbox "$text" "$height" "$width" "$init" 3>&1 1>&2 2>&3 || true
}

dialog_yesno(){
  local title="$1" text="$2" height="${3:-8}" width="${4:-60}"
  $DIALOG_CMD --title "$title" --yesno "$text" "$height" "$width" 3>&1 1>&2 2>&3
}

dialog_msgbox(){
  local title="$1" text="$2" height="${3:-10}" width="${4:-60}"
  $DIALOG_CMD --title "$title" --msgbox "$text" "$height" "$width" 3>&1 1>&2 2>&3 || true
}

dialog_infobox(){
  local title="$1" text="$2" height="${3:-6}" width="${4:-50}"
  $DIALOG_CMD --title "$title" --infobox "$text" "$height" "$width" 3>&1 1>&2 2>&3 || true
}

# ------------ Ruby helpers ------------
ruby_version(){ ruby -e 'print RUBY_VERSION' 2>/dev/null || echo "0.0.0"; }
ruby_ver_ok(){ ruby -e 'v=ARGV[0].split(".").map(&:to_i); puts (v[0]>3 || (v[0]==3 && v[1]>=4)) ? "ok" : "no"' "$(ruby_version)" 2>/dev/null | grep -q ok; }
rbenv_active(){ command -v rbenv >/dev/null 2>&1 && [[ $(command -v ruby) == *"/.rbenv/shims/ruby" ]]; }

ensure_ruby_34(){
  if ruby_ver_ok; then note "Ruby $(ruby_version) OK (>= 3.4)"; return 0; fi

  local current_ver; current_ver="$(ruby_version)"
  warn "Ruby ${current_ver} < 3.4 detected. trmnlp requires Ruby ~> 3.4."

  echo ""
  read -r -p "Install Ruby 3.4 via rbenv now? [y/N] " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    die "Ruby 3.4+ is required. Please install manually and re-run."
  fi

  note "Installing Ruby 3.4 build dependencies..."
  apt_install git build-essential autoconf bison \
    libssl-dev zlib1g-dev libreadline-dev libyaml-dev \
    libffi-dev libgdbm-dev libgmp-dev libncurses5-dev libncursesw5-dev

  if ! command -v rbenv >/dev/null 2>&1; then
    note "Installing rbenv..."
    if [[ -d "${HOME}/.rbenv" ]]; then
      warn "~/.rbenv already exists; skipping clone."
    else
      run git clone https://github.com/rbenv/rbenv.git "${HOME}/.rbenv"
    fi

    export RBENV_ROOT="${HOME}/.rbenv"
    export PATH="${RBENV_ROOT}/bin:${PATH}"

    if [[ ! -d "${HOME}/.rbenv/plugins/ruby-build" ]]; then
      note "Installing ruby-build plugin..."
      run git clone https://github.com/rbenv/ruby-build.git "${HOME}/.rbenv/plugins/ruby-build"
    fi

    if ! grep -q 'RBENV_ROOT' "${HOME}/.bashrc" 2>/dev/null; then
      note "Adding rbenv to ~/.bashrc..."
      {
        echo ''
        echo 'export RBENV_ROOT="$HOME/.rbenv"'
        echo 'export PATH="$RBENV_ROOT/bin:$PATH"'
        echo 'eval "$("$RBENV_ROOT/bin/rbenv" init - bash)"'
      } >> "${HOME}/.bashrc"
    fi

    eval "$("${RBENV_ROOT}/bin/rbenv" init - bash)" || true
  fi

  local target_ruby="3.4.1"
  if ! rbenv versions --bare 2>/dev/null | grep -q "^${target_ruby}$"; then
    note "Building Ruby ${target_ruby} (this may take a while. Get a coffee! 10-20 minutes on a Pi)..."
    run rbenv install "$target_ruby"
  fi

  note "Setting Ruby ${target_ruby} as global default..."
  run rbenv global "$target_ruby"
  eval "$(rbenv init - bash)" || true
  run rbenv rehash || true

  if ruby_ver_ok; then
    note "Ruby $(ruby_version) installed and active."
  else
    die "Ruby installation completed but version check failed. Please restart your shell and re-run."
  fi
}

# ------------ apt helper ------------
apt_install(){
  local pkgs=() p; for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p"); done
  ((${#pkgs[@]})) || return 0
  note "Installing: ${pkgs[*]}"; run sudo apt-get update -y; run sudo apt-get install -y "${pkgs[@]}"
}

# ------------ LAN / proxy helpers ------------
lan_ip(){ hostname -I 2>/dev/null | awk '{print $1}'; }

ensure_proxy_dep(){
  [[ "${ENABLE_PROXY}" == "1" ]] || return 0
  [[ -x "${SOCAT_BIN}" ]] && return 0
  warn "socat not found; installing..."
  apt_install socat
  [[ -x "${SOCAT_BIN}" ]] || die "socat not available at ${SOCAT_BIN}"
}

kill_existing_socat_on_port(){
  local pids; pids="$(pgrep -f "socat .*TCP-LISTEN:${BIND_PORT}" || true)"
  if [[ -n "$pids" ]]; then
    warn "Killing stale proxy on ${BIND_PORT}: $pids"
    if [[ "${PRINT_ONLY}" == "1" ]]; then echo '$ kill '"$pids"; else kill $pids 2>/dev/null || true; sleep 0.2; fi
  fi
  rm -f "${PROXY_PID_DIR}"/*.proxy.pid 2>/dev/null || true
}
start_proxy_fg(){
  PROXY_PID_OUT=""; [[ "${ENABLE_PROXY}" == "1" ]] || return 0
  ensure_proxy_dep; kill_existing_socat_on_port
  local ip; ip="$(lan_ip)"; [[ -z "$ip" ]] && { warn "No LAN IP; skipping proxy."; return 0; }
  if [[ "${PRINT_ONLY}" == "1" ]]; then
    echo '$ '"${SOCAT_BIN}" "TCP-LISTEN:${BIND_PORT},bind=${ip},reuseaddr,fork" "TCP:127.0.0.1:${BIND_PORT}"; return 0
  fi
  "${SOCAT_BIN}" "TCP-LISTEN:${BIND_PORT},bind=${ip},reuseaddr,fork" "TCP:127.0.0.1:${BIND_PORT}" & PROXY_PID_OUT=$!
  note "Proxy http://${ip}:${BIND_PORT} → 127.0.0.1:${BIND_PORT} (pid ${PROXY_PID_OUT})"
}
stop_proxy_fg(){ local pid="$1"; [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; }
start_proxy_daemon(){
  [[ "${ENABLE_PROXY}" == "1" ]] || return 0
  ensure_proxy_dep; kill_existing_socat_on_port
  local plugin="$1" ip; ip="$(lan_ip)"; [[ -z "$ip" ]] && { warn "No LAN IP; skipping proxy."; return 0; }
  local pidf="${PROXY_PID_DIR}/${plugin}.proxy.pid"
  if [[ -f "$pidf" ]] && ps -p "$(cat "$pidf")" >/dev/null 2>&1; then return 0; fi
  if [[ "${PRINT_ONLY}" == "1" ]]; then
    echo '$ '"${SOCAT_BIN}" "TCP-LISTEN:${BIND_PORT},bind=${ip},reuseaddr,fork" "TCP:127.0.0.1:${BIND_PORT}"
    return 0
  fi
  "${SOCAT_BIN}" "TCP-LISTEN:${BIND_PORT},bind=${ip},reuseaddr,fork" "TCP:127.0.0.1:${BIND_PORT}" & echo $! > "$pidf"
  note "Proxy http://${ip}:${BIND_PORT} → 127.0.0.1:${BIND_PORT} (pid $(cat "$pidf"))"
}
stop_proxy_daemon(){ local plugin="$1"; local pidf="${PROXY_PID_DIR}/${plugin}.proxy.pid"; [[ -f "$pidf" ]] || return 0; kill "$(cat "$pidf")" 2>/dev/null || true; rm -f "$pidf"; }

# ------------ Bundler / repo ------------
ensure_bundler_lock_version(){ run gem install --no-document bundler -v 2.6.2 || true; }
ensure_repo_checkout(){ [[ -d "${REPO_DIR}/.git" ]] || { note "Cloning repo to ${REPO_DIR}"; run git clone https://github.com/usetrmnl/trmnlp.git "${REPO_DIR}"; }; }
repo_pull_and_bundle(){ ensure_repo_checkout; ensure_bundler_lock_version; if [[ "${PRINT_ONLY}" == "1" ]]; then echo '$ (cd '"${REPO_DIR}"' && git pull --ff-only && bundle _2.6.2_ install)'; else (cd "${REPO_DIR}" && run git pull --ff-only && bundle _2.6.2_ install); fi; }
repo_commit_short(){ git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown"; }
repo_branch(){ git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"; }
repo_last_commit(){ git -C "${REPO_DIR}" log -1 --pretty='format:%h %ad %s' --date=short 2>/dev/null || echo "unknown"; }
install_gem_from_head(){
  repo_pull_and_bundle; ensure_repo_checkout; ensure_bundler_lock_version
  ( cd "${REPO_DIR}"
    if [[ "${PRINT_ONLY}" == "1" ]]; then
      echo '$ gem build trmnl_preview.gemspec'
      echo '$ gem install --no-document ./trmnl_preview-*.gem'
    else
      gem build trmnl_preview.gemspec
      gem install --no-document ./trmnl_preview-*.gem
    fi
  )
  command -v rbenv >/dev/null 2>&1 && run rbenv rehash || true
}

# ------------ Plugin picker ------------
get_plugins(){ shopt -s nullglob; local e name; for e in "$BASE_DIR"/*; do [[ -d "$e" ]] || continue; name="${e##*/}"; [[ "${SHOW_BACKUPS}" == "0" && "$name" == *.bak-* ]] && continue; printf '%s\n' "$name"; done | sort; shopt -u nullglob; }

pick_plugin(){
  local arr=() choice=""
  while IFS= read -r p; do arr+=("$p"); done < <(get_plugins)
  (( ${#arr[@]} )) || { warn "No plugins found."; return; }

  if [[ -n "$DIALOG_CMD" ]]; then
    local items=() i=1
    for p in "${arr[@]}"; do
      items+=("$p" "")
      ((i++))
    done
    choice="$(dialog_menu "Select Plugin" "Choose a plugin (${#arr[@]} found):" "$(dlg_h 20)" "$(dlg_w 60)" 12 "${items[@]}")"
    choice="$(trim "$choice")"
  else
    { printf "[*] Scanned %s — found %d plugin(s).\n" "$BASE_DIR" "${#arr[@]}"
      local PS3="Select a plugin by number (or 'q' to cancel): "
      select choice in "${arr[@]}"; do case "$REPLY" in q|Q|"") choice=""; break;; esac; [[ -n "$choice" ]] && break || echo "Invalid selection."; done; } >&2
  fi
  printf '%s\n' "$(trim "$choice")"
}

# ------------ trmnlp command wrapper ------------
run_trmnlp(){
  if [[ "${ENGINE}" == "repo" ]]; then
    ensure_repo_checkout
    ensure_bundler_lock_version
    run env BUNDLE_GEMFILE="${REPO_DIR}/Gemfile" \
      bundle _2.6.2_ exec ruby -I "${REPO_DIR}/lib" "${REPO_DIR}/bin/trmnlp" "$@"
  else
    if ! command -v trmnlp >/dev/null 2>&1; then
      err "trmnlp command not found."
      warn "Either:"
      warn "  1) Install the gem: Choose menu option 'U' to build+install gem, OR"
      warn "  2) Switch to repo mode: Choose menu option 'E' to switch engine to 'repo'"
      return 1
    fi
    run trmnlp "$@"
  fi
}

# ------------ xvfb helper for PNG rendering ------------
needs_xvfb(){
  [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]
}

set_xvfb_cmd(){
  XVFB_CMD=()
  if needs_xvfb && command -v xvfb-run >/dev/null 2>&1; then
    XVFB_CMD=(xvfb-run --auto-servernum --server-args="-screen 0 1280x720x24")
  fi
}

png_env_vars(){
  local ff_bin="${1:-}"
  local vars=""
  local gd_bin; gd_bin="$(find_geckodriver || true)"
  [[ -n "$gd_bin" ]] && vars+="SE_GECKODRIVER=${gd_bin} "
  vars+="MOZ_HEADLESS=1 "
  vars+="LIBGL_ALWAYS_SOFTWARE=1 "
  vars+="MOZ_DISABLE_GFX_SANITY_TEST=1 "
  vars+="MOZ_HEADLESS_WIDTH=800 "
  vars+="MOZ_HEADLESS_HEIGHT=480 "
  vars+="MOZ_NO_REMOTE=1 "
  vars+="MOZ_PROFILE_PATH=${FF_PROFILE_DIR} "
  if [[ -n "$ff_bin" ]]; then
    vars+="TRMNL_PREVIEW_FIREFOX=${ff_bin} "
  fi
  echo "$vars"
}

# ------------ Actions ------------
init_plugin(){
  read -r -p "New plugin folder name: " name; name="$(trim "$name")"; [[ -n "$name" ]] || { warn "Canceled."; return; }
  local dest="${BASE_DIR}/${name}"; [[ -e "$dest" ]] && { warn "Exists: $dest"; return; }
  ensure_base_dir; note "Initializing ${dest} ..."; (cd "${BASE_DIR}" && run_trmnlp init "$name"); note "Created ${dest}"
}
login_interactive(){ note "Running 'trmnlp login'..."; run_trmnlp login; }
save_api_key(){
  ensure_secrets; read -rsp "Paste your TRMNL API key (hidden): " key; echo ""; key="$(trim "$key")"; [[ -z "$key" ]] && { warn "No key entered."; return; }
  umask 077
  if grep -q '^TRMNL_API_KEY=' "${SECRETS_FILE}"; then sed -i.bak 's/^TRMNL_API_KEY=.*/TRMNL_API_KEY='"$(printf '%q' "$key")"'/' "${SECRETS_FILE}"; else printf 'TRMNL_API_KEY=%q\n' "$key" >> "${SECRETS_FILE}"; fi
  note "Saved to ${SECRETS_FILE}."
}
clone_plugin(){
  ensure_secrets
  read -r -p "Local folder name to create (or overwrite): " name; name="$(trim "$name")"; [[ -n "$name" ]] || { warn "Canceled."; return; }
  read -r -p "TRMNL plugin ID to clone (numeric plugin_setting_id): " pid; pid="$(trim "$pid")"; [[ -n "$pid" ]] || { warn "Canceled."; return; }
  local dest="${BASE_DIR}/${name}"
  if [[ -e "$dest" ]]; then
    echo ""; bold "Destination exists: ${dest}"; echo "  1) Overwrite (DELETE)"; echo "  2) Backup then overwrite"; echo "  3) Choose different name"; echo "  q) Cancel"
    read -r -p "Select: " ch; ch="$(trim "$ch")"
    case "$ch" in
      1) read -r -p "DELETE '${dest}'? [y/N] " c; [[ "$c" =~ ^[Yy]$ ]] || { warn "Canceled."; return; }; run rm -rf -- "$dest" ;;
      2) run mv -- "$dest" "${dest}.bak-$(ts)" ;;
      3) read -r -p "New local name: " name2; name2="$(trim "$name2")"; [[ -z "$name2" ]] && { warn "Canceled."; return; }; dest="${BASE_DIR}/${name2}" ;;
      q|Q|"") warn "Canceled."; return ;;
      *) warn "Invalid choice." ;;
    esac
  fi
  ensure_base_dir
  if grep -q '^TRMNL_API_KEY=' "${SECRETS_FILE}" 2>/dev/null; then source "${SECRETS_FILE}"; export TRMNL_API_KEY; fi

  local has_clone=0
  if [[ "${ENGINE}" == "repo" ]] && [[ -d "${REPO_DIR}" ]]; then
    has_clone=1
  elif command -v trmnlp >/dev/null 2>&1 && trmnlp help 2>/dev/null | grep -q '\bclone\b'; then
    has_clone=1
  fi

  if [[ $has_clone -eq 1 ]]; then
    (cd "${BASE_DIR}" && run_trmnlp clone "$(basename "$dest")" "$pid")
  else
    warn "Your trmnlp lacks 'clone'. Using TRMNL CLI instead."
    run bash -lc "command -v trmnl >/dev/null || curl -LSs https://trmnl.terminalwire.sh | bash"
    run trmnl login
    (cd "${BASE_DIR}" && run trmnl plugin clone "$(basename "$dest")" "$pid")
  fi
  note "Cloned to ${dest}"
}

# ---- Nightly detection helpers ----
find_firefox_nightly(){
  local c candidate
  for c in "${TRMNL_PREVIEW_FIREFOX:-}" /usr/bin/firefox-nightly /usr/local/bin/firefox-nightly "${FFN_DIR}/firefox"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  if command -v firefox-nightly >/dev/null 2>&1; then
    candidate="$(command -v firefox-nightly)"
    [[ -x "$candidate" ]] && { echo "$candidate"; return 0; }
  fi
  return 1
}

ensure_firefox_symlink(){
  local ff_bin; ff_bin="$(find_firefox_nightly || true)"
  [[ -n "$ff_bin" ]] || return 0
  if command -v firefox >/dev/null 2>&1; then
    return 0
  fi
  note "Creating 'firefox' symlink → ${ff_bin} (selenium auto-discovery)"
  if [[ "${PRINT_ONLY}" == "1" ]]; then
    echo "$ sudo ln -sf ${ff_bin} /usr/local/bin/firefox"
  else
    sudo ln -sf "$ff_bin" /usr/local/bin/firefox || warn "Could not create firefox symlink"
  fi
}

serve_foreground(){
  local plugin="${1:-}"; [[ -z "$plugin" ]] && plugin="$(pick_plugin)"; plugin="$(trim "$plugin")"
  [[ -n "$plugin" ]] || { warn "No plugin selected."; return; }
  [[ -d "${BASE_DIR}/${plugin}" ]] || die "Not found: ${BASE_DIR}/${plugin}"
  if [[ "${ENGINE}" == "repo" ]]; then repo_pull_and_bundle; fi

  local PROXY_PID=""
  if [[ "${ENABLE_PROXY}" == "1" ]]; then start_proxy_fg; PROXY_PID="${PROXY_PID_OUT:-}"; fi

  local FF_BIN; FF_BIN="$(find_firefox_nightly || true)"
  if [[ -z "$FF_BIN" ]]; then
    echo ""
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    err "  Firefox Nightly NOT FOUND!"
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "  PNG export (/render/full.png) WILL FAIL with runtime errors."
    warn "  HTML preview (/render/full.html) will still work."
    warn ""
    warn "  To enable PNG rendering, install Firefox Nightly:"
    warn "    • Run menu option 'N' from this script, OR"
    warn "    • Manually install and set TRMNL_PREVIEW_FIREFOX=/path/to/firefox"
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -r -p "Continue anyway? [y/N] " cont
    [[ "$cont" =~ ^[Yy]$ ]] || { warn "Aborted."; return; }
  elif [[ ! -x "$FF_BIN" ]]; then
    warn "Firefox Nightly path exists but is not executable: $FF_BIN"
    warn "PNG export (/render/full.png) will NOT work."
    FF_BIN=""
  fi

  set_xvfb_cmd

  if [[ -n "$FF_BIN" ]]; then
    ensure_geckodriver || true
    ensure_firefox_symlink
  fi

  note "Engine: ${ENGINE}  $( [[ "${ENGINE}" == "repo" ]] && echo "(HEAD $(repo_commit_short) on $(repo_branch))" )"
  note "Nightly: ${FF_BIN:-<not found>} (used for PNG export)"
  note "Geckodriver: $(geckodriver --version 2>/dev/null | head -1 || echo '<not found>')"
  [[ ${#XVFB_CMD[@]} -gt 0 ]] && note "xvfb: active (no DISPLAY detected)"
  [[ "${ENABLE_PROXY}" == "1" ]] && note "Open from LAN: http://$(lan_ip):${BIND_PORT}" || note "Open locally : http://127.0.0.1:${BIND_PORT}"
  note "Serving '${plugin}' (Ctrl+C to stop)..."

  local GD_BIN; GD_BIN="$(find_geckodriver || true)"
  local se_gd_env=""
  [[ -n "$GD_BIN" ]] && se_gd_env="SE_GECKODRIVER=${GD_BIN}"

  if [[ "${ENGINE}" == "repo" ]]; then
    if [[ -n "$FF_BIN" ]]; then
      ( cd "${BASE_DIR}/${plugin}" && run "${XVFB_CMD[@]}" env \
        PATH="/usr/local/bin:$PATH" \
        ${se_gd_env} \
        TRMNL_PREVIEW_FIREFOX="${FF_BIN}" \
        MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
        MOZ_HEADLESS_WIDTH=800 MOZ_HEADLESS_HEIGHT=480 \
        MOZ_NO_REMOTE=1 MOZ_PROFILE_PATH="${FF_PROFILE_DIR}" \
        BUNDLE_GEMFILE="${REPO_DIR}/Gemfile" PORT="${BIND_PORT}" \
        bundle _2.6.2_ exec ruby -I "${REPO_DIR}/lib" "${REPO_DIR}/bin/trmnlp" serve ) || true
    else
      ( cd "${BASE_DIR}/${plugin}" && run "${XVFB_CMD[@]}" env \
        PATH="/usr/local/bin:$PATH" \
        ${se_gd_env} \
        MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
        BUNDLE_GEMFILE="${REPO_DIR}/Gemfile" PORT="${BIND_PORT}" \
        bundle _2.6.2_ exec ruby -I "${REPO_DIR}/lib" "${REPO_DIR}/bin/trmnlp" serve ) || true
    fi
  else
    if [[ -n "$FF_BIN" ]]; then
      ( cd "${BASE_DIR}/${plugin}" && run "${XVFB_CMD[@]}" env \
        PATH="/usr/local/bin:$PATH" \
        ${se_gd_env} \
        TRMNL_PREVIEW_FIREFOX="${FF_BIN}" \
        MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
        MOZ_HEADLESS_WIDTH=800 MOZ_HEADLESS_HEIGHT=480 \
        MOZ_NO_REMOTE=1 MOZ_PROFILE_PATH="${FF_PROFILE_DIR}" \
        PORT="${BIND_PORT}" trmnlp serve ) || true
    else
      ( cd "${BASE_DIR}/${plugin}" && run "${XVFB_CMD[@]}" env \
        PATH="/usr/local/bin:$PATH" \
        ${se_gd_env} \
        MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
        PORT="${BIND_PORT}" trmnlp serve ) || true
    fi
  fi

  [[ -n "${PROXY_PID}" ]] && stop_proxy_fg "${PROXY_PID}"
}

serve_daemon(){
  local plugin="${1:-}"; [[ -z "$plugin" ]] && plugin="$(pick_plugin)"; plugin="$(trim "$plugin")"
  [[ -n "$plugin" ]] || { warn "No plugin selected."; return; }
  [[ -d "${BASE_DIR}/${plugin}" ]] || die "Not found: ${BASE_DIR}/${plugin}"
  if [[ "${ENGINE}" == "repo" ]]; then repo_pull_and_bundle; fi

  local pidf="${PID_DIR}/${plugin}.pid" logf="${LOG_DIR}/${plugin}.log"
  if [[ -f "$pidf" ]] && ps -p "$(cat "$pidf")" >/dev/null 2>&1; then warn "Already running (PID $(cat "$pidf"))."; return; fi
  start_proxy_daemon "${plugin}"

  local FF_BIN; FF_BIN="$(find_firefox_nightly || true)"
  if [[ -z "$FF_BIN" ]]; then
    echo ""
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    err "  Firefox Nightly NOT FOUND!"
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "  PNG export (/render/full.png) WILL FAIL with runtime errors."
    warn "  HTML preview (/render/full.html) will still work."
    warn ""
    warn "  To enable PNG rendering, install Firefox Nightly:"
    warn "    • Run menu option 'N' from this script, OR"
    warn "    • Manually install and set TRMNL_PREVIEW_FIREFOX=/path/to/firefox"
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
  elif [[ ! -x "$FF_BIN" ]]; then
    warn "Firefox Nightly path exists but is not executable: $FF_BIN"
    warn "PNG export (/render/full.png) will NOT work."
    FF_BIN=""
  fi

  set_xvfb_cmd

  if [[ -n "$FF_BIN" ]]; then
    ensure_geckodriver || true
    ensure_firefox_symlink
  fi

  note "Engine: ${ENGINE}  $( [[ "${ENGINE}" == "repo" ]] && echo "(HEAD $(repo_commit_short) on $(repo_branch))" )"
  note "Nightly: ${FF_BIN:-<not found>} (used for PNG export)"
  note "Geckodriver: $(geckodriver --version 2>/dev/null | head -1 || echo '<not found>')"
  [[ ${#XVFB_CMD[@]} -gt 0 ]] && note "xvfb: active (no DISPLAY detected)"
  note "Logs: ${logf}"

  local png_envs; png_envs="$(png_env_vars "$FF_BIN")"
  local GD_BIN; GD_BIN="$(find_geckodriver || true)"
  local se_gd_env=""
  [[ -n "$GD_BIN" ]] && se_gd_env="SE_GECKODRIVER=${GD_BIN}"

  if [[ "${PRINT_ONLY}" == "1" ]]; then
    if [[ "${ENGINE}" == "repo" ]]; then
      if [[ -n "$FF_BIN" ]]; then
        echo '$ nohup sh -lc '"$(printf "%q " "cd" "${BASE_DIR}/${plugin}" "&&" \
          "PATH=/usr/local/bin:\$PATH" \
          ${se_gd_env:+"${se_gd_env}"} \
          "TRMNL_PREVIEW_FIREFOX=${FF_BIN}" \
          "MOZ_HEADLESS=1" "LIBGL_ALWAYS_SOFTWARE=1" "MOZ_DISABLE_GFX_SANITY_TEST=1" \
          "MOZ_HEADLESS_WIDTH=800" "MOZ_HEADLESS_HEIGHT=480" \
          "MOZ_NO_REMOTE=1" "MOZ_PROFILE_PATH=${FF_PROFILE_DIR}" \
          "BUNDLE_GEMFILE=${REPO_DIR}/Gemfile" "PORT=${BIND_PORT}" \
          "bundle" "_2.6.2_" "exec" "ruby" "-I" "${REPO_DIR}/lib" "${REPO_DIR}/bin/trmnlp" "serve")"' >> '"${logf}"' 2>&1 & echo $! > '"${pidf}"'
      else
        echo '$ nohup sh -lc '"$(printf "%q " "cd" "${BASE_DIR}/${plugin}" "&&" \
          "PATH=/usr/local/bin:\$PATH" \
          ${se_gd_env:+"${se_gd_env}"} \
          "DISABLE_PNG_RENDERING=1" \
          "MOZ_HEADLESS=1" "LIBGL_ALWAYS_SOFTWARE=1" "MOZ_DISABLE_GFX_SANITY_TEST=1" \
          "BUNDLE_GEMFILE=${REPO_DIR}/Gemfile" "PORT=${BIND_PORT}" \
          "bundle" "_2.6.2_" "exec" "ruby" "-I" "${REPO_DIR}/lib" "${REPO_DIR}/bin/trmnlp" "serve")"' >> '"${logf}"' 2>&1 & echo $! > '"${pidf}"'
      fi
    else
      if [[ -n "$FF_BIN" ]]; then
        echo '$ nohup sh -lc '"$(printf "%q " "cd" "${BASE_DIR}/${plugin}" "&&" \
          "PATH=/usr/local/bin:\$PATH" \
          ${se_gd_env:+"${se_gd_env}"} \
          "TRMNL_PREVIEW_FIREFOX=${FF_BIN}" \
          "MOZ_HEADLESS=1" "LIBGL_ALWAYS_SOFTWARE=1" "MOZ_DISABLE_GFX_SANITY_TEST=1" \
          "MOZ_HEADLESS_WIDTH=800" "MOZ_HEADLESS_HEIGHT=480" \
          "MOZ_NO_REMOTE=1" "MOZ_PROFILE_PATH=${FF_PROFILE_DIR}" \
          "PORT=${BIND_PORT}" "trmnlp" "serve")"' >> '"${logf}"' 2>&1 & echo $! > '"${pidf}"'
      else
        echo '$ nohup sh -lc '"$(printf "%q " "cd" "${BASE_DIR}/${plugin}" "&&" \
          "PATH=/usr/local/bin:\$PATH" \
          ${se_gd_env:+"${se_gd_env}"} \
          "DISABLE_PNG_RENDERING=1" \
          "MOZ_HEADLESS=1" "LIBGL_ALWAYS_SOFTWARE=1" "MOZ_DISABLE_GFX_SANITY_TEST=1" \
          "PORT=${BIND_PORT}" "trmnlp" "serve")"' >> '"${logf}"' 2>&1 & echo $! > '"${pidf}"'
      fi
    fi
  else
    local xvfb_sh=""
    if [[ ${#XVFB_CMD[@]} -gt 0 ]]; then xvfb_sh="xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' "; fi
    local se_gd_sh=""
    [[ -n "$GD_BIN" ]] && se_gd_sh="SE_GECKODRIVER='${GD_BIN}' "

    if [[ "${ENGINE}" == "repo" ]]; then
      if [[ -n "$FF_BIN" ]]; then
        nohup sh -lc "cd ${BASE_DIR}/${plugin} && \
          PATH='/usr/local/bin:\$PATH' \
          ${se_gd_sh}\
          TRMNL_PREVIEW_FIREFOX='${FF_BIN}' \
          MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
          MOZ_HEADLESS_WIDTH=800 MOZ_HEADLESS_HEIGHT=480 \
          MOZ_NO_REMOTE=1 MOZ_PROFILE_PATH='${FF_PROFILE_DIR}' \
          BUNDLE_GEMFILE='${REPO_DIR}/Gemfile' PORT='${BIND_PORT}' \
          ${xvfb_sh}bundle _2.6.2_ exec ruby -I '${REPO_DIR}/lib' '${REPO_DIR}/bin/trmnlp' serve" >> "${logf}" 2>&1 &
      else
        nohup sh -lc "cd ${BASE_DIR}/${plugin} && \
          PATH='/usr/local/bin:\$PATH' \
          ${se_gd_sh}\
          DISABLE_PNG_RENDERING=1 \
          MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
          BUNDLE_GEMFILE='${REPO_DIR}/Gemfile' PORT='${BIND_PORT}' \
          bundle _2.6.2_ exec ruby -I '${REPO_DIR}/lib' '${REPO_DIR}/bin/trmnlp' serve" >> "${logf}" 2>&1 &
      fi
    else
      if [[ -n "$FF_BIN" ]]; then
        nohup sh -lc "cd ${BASE_DIR}/${plugin} && \
          PATH='/usr/local/bin:\$PATH' \
          ${se_gd_sh}\
          TRMNL_PREVIEW_FIREFOX='${FF_BIN}' \
          MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
          MOZ_HEADLESS_WIDTH=800 MOZ_HEADLESS_HEIGHT=480 \
          MOZ_NO_REMOTE=1 MOZ_PROFILE_PATH='${FF_PROFILE_DIR}' \
          PORT='${BIND_PORT}' ${xvfb_sh}trmnlp serve" >> "${logf}" 2>&1 &
      else
        nohup sh -lc "cd ${BASE_DIR}/${plugin} && \
          PATH='/usr/local/bin:\$PATH' \
          ${se_gd_sh}\
          DISABLE_PNG_RENDERING=1 \
          MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
          PORT='${BIND_PORT}' trmnlp serve" >> "${logf}" 2>&1 &
      fi
    fi
    echo $! > "${pidf}"; sleep 1; note "PID $(cat "${pidf}")"
  fi
}

stop_daemon(){
  local plugin="${1:-}"; [[ -z "$plugin" ]] && plugin="$(pick_plugin)"; plugin="$(trim "$plugin")"
  [[ -n "$plugin" ]] || { warn "No plugin selected."; return; }
  local pidf="${PID_DIR}/${plugin}.pid"
  if [[ -f "$pidf" ]]; then
    local pid; pid="$(cat "$pidf")"
    if [[ "${PRINT_ONLY}" == "1" ]]; then echo '$ kill '"$pid"' && rm -f '"${pidf}"; else kill "$pid" 2>/dev/null || true; rm -f "$pidf"; note "Stopped app PID ${pid}"; fi
  else warn "No PID file for ${plugin}."; fi
  stop_proxy_daemon "${plugin}"
}

push_plugin(){
  ensure_secrets
  local plugin="${1:-}"; [[ -z "$plugin" ]] && plugin="$(pick_plugin)"; plugin="$(trim "$plugin")"
  [[ -n "$plugin" ]] || { warn "No plugin selected."; return; }
  [[ -d "${BASE_DIR}/${plugin}" ]] || die "Not found: ${BASE_DIR}/${plugin}"
  if grep -q '^TRMNL_API_KEY=' "${SECRETS_FILE}" 2>/dev/null; then source "${SECRETS_FILE}"; export TRMNL_API_KEY; fi

  local has_push=0
  if [[ "${ENGINE}" == "repo" ]] && [[ -d "${REPO_DIR}" ]]; then
    has_push=1
  elif command -v trmnlp >/dev/null 2>&1 && trmnlp help 2>/dev/null | grep -q '\bpush\b'; then
    has_push=1
  fi

  if [[ $has_push -eq 1 ]]; then
    (cd "${BASE_DIR}/${plugin}" && run_trmnlp push)
  else
    warn "Your trmnlp lacks 'push'. Using TRMNL CLI."
    run bash -lc "command -v trmnl >/dev/null || curl -LSs https://trmnl.terminalwire.sh | bash"
    run trmnl login
    (cd "${BASE_DIR}/${plugin}" && run trmnl plugin push)
  fi
}

list_plugins(){ get_plugins || true; }

# ----- Update choices -----
update_gem_from_head_menu(){ install_gem_from_head; note "Gem installed from HEAD. which trmnlp → $(command -v trmnlp || echo '<not found>')"; }
update_repo_only_menu(){ repo_pull_and_bundle; note "Repo updated to $(repo_commit_short) on $(repo_branch): $(repo_last_commit)"; }

# ----- Engine helpers -----
switch_engine(){
  if [[ -n "$DIALOG_CMD" ]]; then
    local choice; choice="$(dialog_menu "Switch Engine" "Current engine: ${ENGINE}" "$(dlg_h 10)" "$(dlg_w 50)" 2 \
      "gem" "Use installed trmnl_preview gem" \
      "repo" "Use local git repo checkout")"
    choice="$(trim "$choice")"
    [[ -n "$choice" ]] && ENGINE="$choice" && save_settings
    note "Engine set to: ${ENGINE}"
  else
    echo "Current engine: ${ENGINE}"; echo "  1) gem"; echo "  2) repo"; read -rp "Choose [1/2]: " ch
    case "$ch" in 1) ENGINE="gem";; 2) ENGINE="repo";; *) warn "No change.";; esac
    save_settings; note "Engine set to: ${ENGINE}"
  fi
}

show_engine_info(){
  local info=""
  info+="ENGINE   : ${ENGINE}\n"
  info+="RUBY     : $(ruby_version) $(rbenv_active && echo '(rbenv)')\n"
  if [[ "${ENGINE}" == "gem" ]]; then
    info+="which    : $(command -v trmnlp || echo '<not found>')\n"
    info+="gem dir  : $(ruby -e 'print Gem.dir' 2>/dev/null || echo '?')\n"
    info+="gem which: $(ruby -e 'begin; require "rubygems"; s=Gem::Specification.find_by_name("trmnl_preview") rescue nil; puts(s && s.full_gem_path) end' 2>/dev/null || true)\n"
    info+="gem list : $(gem list ^trmnl_preview -a 2>/dev/null | tr -d '\n')\n"
  else
    info+="repo dir : ${REPO_DIR}\n"
    info+="branch   : $(repo_branch)\n"
    info+="commit   : $(repo_last_commit)\n"
    info+="bundler  : $(bundle -v 2>/dev/null || echo 'bundle not found')\n"
  fi

  if [[ -n "$DIALOG_CMD" ]]; then
    dialog_msgbox "Engine Info" "$(echo -e "$info")" "$(dlg_h 14)" "$(dlg_w 70)"
  else
    echo ""; bold "Engine info"; echo -e "$info"
  fi
}

# ------------ Firefox Nightly (APT-first, tar fallback) ------------
arch_id(){ case "$(uname -m)" in aarch64) echo "linux-aarch64";; armv7l) echo "linux-arm";; armv6l) echo "linux-armv6";; x86_64) echo "linux64";; *) echo "unknown";; esac; }
ffn_dep_install(){
  apt_install xz-utils bzip2 ca-certificates curl \
             libgtk-3-0 libdbus-1-3 libx11-xcb1 libxss1 libxcomposite1 \
             libxdamage1 libxfixes3 libnss3 libasound2 libxrandr2 libxtst6 \
             fonts-noto fonts-noto-color-emoji \
             xvfb
}
download_ffn_tarball(){
  local out="$1" arch="$(arch_id)" lang="${FFN_LANG}"
  if [[ -n "${FFN_URL}" ]]; then
    if [[ "${PRINT_ONLY}" == "1" ]]; then echo '$ curl -fL --retry 3 '"${FFN_URL}"' -o '"$out"; return 0; else curl -fL --retry 3 "${FFN_URL}" -o "$out" && { echo "${FFN_URL}" > "${STATE_DIR}/firefox-nightly-source.txt" || true; return 0; }; return 1; fi
  fi
  local -a urls=()
  case "$arch" in
    linux-aarch64) urls+=("https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux64-aarch64&lang=${lang}" "https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux-aarch64&lang=${lang}");;
    linux-arm)     urls+=("https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux-arm&lang=${lang}");;
    linux64)       urls+=("https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux64&lang=${lang}");;
    *) return 2;;
  esac
  local u; for u in "${urls[@]}"; do
    if [[ "${PRINT_ONLY}" == "1" ]]; then echo '$ curl -fL --retry 3 '"$u"' -o '"$out"; return 0; else if curl -fL --retry 3 "$u" -o "$out"; then echo "$u" > "${STATE_DIR}/firefox-nightly-source.txt" || true; return 0; fi; fi
  done
  return 1
}
tar_extract_auto(){
  local file="$1" dest="$2"; local mime; mime="$(file -b --mime-type "$file" 2>/dev/null || true)"; note "Archive type: ${mime:-unknown}"
  if [[ "$mime" == application/x-xz* || "$file" =~ \.tar\.xz$ ]]; then run sudo tar -xJf "$file" -C "$dest" --strip-components=1
  elif [[ "$mime" == application/x-bzip2* || "$file" =~ \.tar\.bz2$ ]]; then run sudo tar -xjf "$file" -C "$dest" --strip-components=1
  else run sudo tar -xf "$file" -C "$dest" --strip-components=1; fi
}

# ------------ Geckodriver (for selenium-webdriver PNG rendering) ------------
geckodriver_version(){
  geckodriver --version 2>/dev/null | head -1 | awk '{print $2}' || true
}

install_geckodriver(){
  local arch; arch="$(uname -m)"
  local gd_arch=""
  case "$arch" in
    aarch64)  gd_arch="linux-aarch64" ;;
    x86_64)   gd_arch="linux64" ;;
    *) warn "Unsupported arch for geckodriver: ${arch}"; return 1 ;;
  esac

  note "Fetching latest geckodriver release tag..."
  local latest_tag
  latest_tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    https://github.com/mozilla/geckodriver/releases/latest 2>/dev/null \
    | grep -oE '[^/]+$')" || true
  if [[ -z "$latest_tag" ]]; then
    warn "Could not determine latest geckodriver version."
    latest_tag="v0.36.0"
    note "Falling back to ${latest_tag}"
  fi

  local url="https://github.com/mozilla/geckodriver/releases/download/${latest_tag}/geckodriver-${latest_tag}-${gd_arch}.tar.gz"
  local tmp="/tmp/geckodriver.tar.gz"

  if [[ "${PRINT_ONLY}" == "1" ]]; then
    echo "$ curl -fL ${url} -o ${tmp}"
    echo '$ sudo tar -xzf '"${tmp}"' -C /usr/local/bin/ geckodriver'
    echo '$ sudo chmod +x /usr/local/bin/geckodriver'
    return 0
  fi

  note "Downloading geckodriver ${latest_tag} for ${gd_arch}..."
  if ! curl -fL --retry 3 "$url" -o "$tmp"; then
    err "Failed to download geckodriver from ${url}"
    return 1
  fi

  note "Installing geckodriver to /usr/local/bin/..."
  sudo tar -xzf "$tmp" -C /usr/local/bin/ geckodriver
  sudo chmod +x /usr/local/bin/geckodriver
  rm -f "$tmp"

  if command -v geckodriver >/dev/null 2>&1; then
    note "geckodriver installed: $(geckodriver --version 2>/dev/null | head -1)"
  else
    warn "geckodriver binary not found on PATH after install."
  fi
}

find_geckodriver(){
  local c
  for c in /usr/local/bin/geckodriver /usr/bin/geckodriver; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  command -v geckodriver 2>/dev/null && return 0
  return 1
}

ensure_geckodriver(){
  if find_geckodriver >/dev/null 2>&1; then
    return 0
  fi
  warn "geckodriver not found. PNG rendering via selenium-webdriver will fail."
  warn "Install it via menu option 'N' (Install Firefox Nightly) or run:"
  warn "  curl -fL https://github.com/mozilla/geckodriver/releases/latest/download/geckodriver-<ver>-linux-aarch64.tar.gz | sudo tar -xz -C /usr/local/bin/"
  return 1
}

install_firefox_nightly(){
  note "Installing Firefox Nightly (APT-first)..."
  if [[ "${PRINT_ONLY}" == "1" ]]; then
    echo '$ sudo install -d -m 0755 /usr/share/keyrings'
    echo '$ wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | gpg --dearmor | sudo tee /usr/share/keyrings/packages.mozilla.org.gpg >/dev/null'
    echo '$ grep -qs "packages.mozilla.org/apt mozilla main" /etc/apt/sources.list.d/mozilla.list || echo "deb [signed-by=/usr/share/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" | sudo tee -a /etc/apt/sources.list.d/mozilla.list >/dev/null'
    echo '$ sudo apt update'
    echo '$ sudo apt install -y firefox-nightly'
  else
    sudo install -d -m 0755 /usr/share/keyrings || true
    if wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | gpg --dearmor | sudo tee /usr/share/keyrings/packages.mozilla.org.gpg >/dev/null; then
      :
    else
      warn "Could not fetch Mozilla key; APT install may fail."
    fi
    if ! grep -qs "packages.mozilla.org/apt mozilla main" /etc/apt/sources.list.d/mozilla.list 2>/dev/null; then
      echo "deb [signed-by=/usr/share/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" | sudo tee -a /etc/apt/sources.list.d/mozilla.list >/dev/null
    fi
    if sudo apt update && sudo apt install -y firefox-nightly; then
      note "Installed firefox-nightly via APT."
    else
      warn "APT install failed; falling back to tarball method."
      install_firefox_nightly_tarball_fallback || return 1
    fi
  fi

  ffn_dep_install

  local bin; bin="$(find_firefox_nightly || true)"
  if [[ -n "$bin" && "$bin" != "/usr/local/bin/firefox-nightly" ]]; then
    run sudo ln -sf "$bin" "${FFN_BIN_LINK}"
  fi

  ensure_firefox_symlink

  if ! command -v geckodriver >/dev/null 2>&1; then
    note "Installing geckodriver (required by selenium-webdriver for PNG rendering)..."
    install_geckodriver || warn "geckodriver install failed; PNG rendering may not work."
  else
    note "geckodriver already installed: $(geckodriver --version 2>/dev/null | head -1)"
  fi

  test_png_renderer
}

install_firefox_nightly_tarball_fallback(){
  note "Falling back to tarball install..."
  local tmp="/tmp/firefox-nightly.tar"
  if ! download_ffn_tarball "$tmp"; then
    warn "Auto-download failed. Provide a local Nightly tar.(xz|bz2) path or press Enter to abort."
    read -rp "Path: " manual; manual="$(trim "$manual")"; [[ -z "$manual" ]] && { warn "Canceled."; return 1; }; tmp="$manual"
  fi
  file "$tmp" || true
  run sudo mkdir -p "${FFN_DIR}"
  tar_extract_auto "$tmp" "${FFN_DIR}"
  run sudo ln -sf "${FFN_DIR}/firefox" "${FFN_BIN_LINK}"
  run hash -r || true
  note "Firefox Nightly installed at ${FFN_DIR} (symlinked as ${FFN_BIN_LINK})"
}

test_png_renderer(){
  local out="/tmp/ff-test.png"; local bin
  bin="$(find_firefox_nightly || true)"
  if [[ -z "$bin" ]]; then warn "firefox-nightly not found on PATH. Try menu 'N' again."; return 1; fi
  if [[ "${PRINT_ONLY}" == "1" ]]; then
    echo '$ '"$bin"' --version'
    echo '$ '"$bin"' --headless --screenshot '"$out"' https://example.com'
    return 0
  fi
  "$bin" --version || true

  set_xvfb_cmd

  if "${XVFB_CMD[@]}" env \
    MOZ_HEADLESS=1 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_GFX_SANITY_TEST=1 \
    MOZ_HEADLESS_WIDTH=800 MOZ_HEADLESS_HEIGHT=480 \
    MOZ_NO_REMOTE=1 MOZ_PROFILE_PATH="${FF_PROFILE_DIR}" \
    "$bin" --headless --screenshot "$out" https://example.com 2>&1; then
    note "Headless screenshot OK: $out"; ls -lh "$out" || true; return 0
  else
    err "Headless run failed."
    warn "Troubleshooting tips:"
    warn "  1. Ensure xvfb is installed: sudo apt install xvfb"
    warn "  2. Check for missing libraries: ldd $bin | grep 'not found'"
    warn "  3. Try manually: MOZ_HEADLESS=1 $bin --headless --screenshot /tmp/test.png https://example.com"
    warn "  4. Check that no other Firefox instance is locking the profile"
    return 1
  fi
}

# ------------ Settings (dialog-aware) ------------
change_settings(){
  if [[ -n "$DIALOG_CMD" ]]; then
    change_settings_dialog
  else
    change_settings_text
  fi
}

change_settings_dialog(){
  local w; w="$(dlg_w 70)"
  local vmax=$(( w - 30 ))
  (( vmax < 15 )) && vmax=15
  local iw; iw="$(dlg_w 76)"

  while true; do
    local rc=0 choice=""
    choice="$($DIALOG_CMD --title "Settings" \
      --cancel-button "Back" \
      --menu "Configure TRMNLP-PiServe" "$(dlg_h 20)" "$w" 9 \
      "BASE_DIR"     "$(trunc $vmax "$BASE_DIR")" \
      "BIND_PORT"    "${BIND_PORT}" \
      "ENABLE_PROXY" "${ENABLE_PROXY} (1=on, 0=off)" \
      "SHOW_BACKUPS" "${SHOW_BACKUPS} (0=hide, 1=show)" \
      "ENGINE"       "${ENGINE} (gem/repo)" \
      "REPO_DIR"     "$(trunc $vmax "$REPO_DIR")" \
      "FFN_LANG"     "${FFN_LANG}" \
      "FFN_URL"      "$(trunc $vmax "${FFN_URL:-(none)}")" \
      3>&1 1>&2 2>&3)" || rc=$?
    choice="$(trim "$choice")"
    [[ -z "$choice" || $rc -ne 0 ]] && break
    local new_val=""
    case "$choice" in
      BASE_DIR)     new_val="$(dialog_inputbox "BASE_DIR" "Plugin root directory:" 8 "$iw" "$BASE_DIR")"
                    new_val="$(trim "$new_val")"; [[ -n "$new_val" ]] && BASE_DIR="$new_val" && ensure_base_dir ;;
      BIND_PORT)    new_val="$(dialog_inputbox "BIND_PORT" "Server port:" 8 40 "$BIND_PORT")"
                    new_val="$(trim "$new_val")"; [[ -n "$new_val" ]] && BIND_PORT="$new_val" ;;
      ENABLE_PROXY) new_val="$(dialog_menu "LAN Proxy" "Enable LAN proxy?" 10 40 2 "1" "Enabled" "0" "Disabled")"
                    new_val="$(trim "$new_val")"; [[ "$new_val" == "0" || "$new_val" == "1" ]] && ENABLE_PROXY="$new_val" ;;
      SHOW_BACKUPS) new_val="$(dialog_menu "Show Backups" "Show *.bak-* directories?" 10 40 2 "0" "Hidden" "1" "Visible")"
                    new_val="$(trim "$new_val")"; [[ "$new_val" == "0" || "$new_val" == "1" ]] && SHOW_BACKUPS="$new_val" ;;
      ENGINE)       new_val="$(dialog_menu "Engine" "Execution engine:" 10 50 2 "gem" "Installed gem" "repo" "Local repo checkout")"
                    new_val="$(trim "$new_val")"; [[ "$new_val" =~ ^(gem|repo)$ ]] && ENGINE="$new_val" ;;
      REPO_DIR)     new_val="$(dialog_inputbox "REPO_DIR" "Local repo path:" 8 "$iw" "$REPO_DIR")"
                    new_val="$(trim "$new_val")"; [[ -n "$new_val" ]] && REPO_DIR="$new_val" ;;
      FFN_LANG)     new_val="$(dialog_inputbox "FFN_LANG" "Firefox Nightly locale:" 8 40 "$FFN_LANG")"
                    new_val="$(trim "$new_val")"; [[ -n "$new_val" ]] && FFN_LANG="$new_val" ;;
      FFN_URL)      new_val="$(dialog_inputbox "FFN_URL" "Custom Nightly URL (blank to clear):" 8 "$iw" "$FFN_URL")"
                    new_val="$(trim "$new_val")"; FFN_URL="$new_val" ;;
    esac
    save_settings
  done
}

change_settings_text(){
  echo ""; echo "Current settings:"
  echo "1) BASE_DIR        = ${BASE_DIR}"
  echo "2) BIND_PORT       = ${BIND_PORT}"
  echo "3) ENABLE_PROXY    = ${ENABLE_PROXY} (1=on, 0=off)"
  echo "4) SHOW_BACKUPS    = ${SHOW_BACKUPS} (0=hide *.bak-*, 1=show)"
  echo "5) ENGINE          = ${ENGINE} (gem/repo)"
  echo "6) REPO_DIR        = ${REPO_DIR}"
  echo "7) FFN_LANG        = ${FFN_LANG}   (Nightly locale)"
  echo "8) FFN_URL         = ${FFN_URL}    (custom Nightly URL override)"
  echo "0) Back"
  read -rp "Change which? " sel || true
  case "$sel" in
    1) read -rp "New BASE_DIR: " v; v="$(trim "$v")"; [[ -n "$v" ]] && BASE_DIR="$v"; ensure_base_dir ;;
    2) read -rp "New BIND_PORT: " v; v="$(trim "$v")"; [[ -n "$v" ]] && BIND_PORT="$v" ;;
    3) read -rp "ENABLE_PROXY (1/0): " v; v="$(trim "$v")"; [[ "$v" == "0" || "$v" == "1" ]] && ENABLE_PROXY="$v" ;;
    4) read -rp "SHOW_BACKUPS (0/1): " v; v="$(trim "$v")"; [[ "$v" == "0" || "$v" == "1" ]] && SHOW_BACKUPS="$v" ;;
    5) read -rp "ENGINE (gem/repo): " v; v="$(trim "$v")"; [[ "$v" =~ ^(gem|repo)$ ]] && ENGINE="$v" || warn "Invalid (gem/repo)";;
    6) read -rp "REPO_DIR: " v; v="$(trim "$v")"; [[ -n "$v" ]] && REPO_DIR="$v";;
    7) read -rp "FFN_LANG: " v; v="$(trim "$v")"; [[ -n "$v" ]] && FFN_LANG="$v";;
    8) read -rp "FFN_URL (blank to clear): " v; v="$(trim "$v")"; FFN_URL="$v";;
    0) ;;
    *) warn "No change." ;;
  esac
  save_settings
}

# ------------ Menu ------------
main_menu(){
  ensure_base_dir
  ensure_ruby_34
  ensure_dialog || true

  if [[ -n "$DIALOG_CMD" ]]; then
    main_menu_dialog
  else
    main_menu_text
  fi
}

main_menu_dialog(){
  local w; w="$(dlg_w 72)"
  local h; h="$(dlg_h 24)"
  local mh=$(( h - 10 ))
  (( mh < 8 )) && mh=8

  while true; do
    local engine_info="${ENGINE}"
    [[ "${ENGINE}" == "repo" ]] && engine_info="${ENGINE} ($(repo_commit_short))"
    local proxy_status="off"
    [[ "${ENABLE_PROXY}" == "1" ]] && proxy_status="on"
    local lan_info=""
    [[ "${ENABLE_PROXY}" == "1" ]] && lan_info="$(lan_ip):${BIND_PORT}" || lan_info="127.0.0.1:${BIND_PORT}"

    local info_text
    info_text="$(printf '%s\n%s\n%s\n%s' \
      "Root:   $(trunc $(( w - 14 )) "$BASE_DIR")" \
      "Ruby:   $(ruby_version)  |  Engine: ${engine_info}" \
      "Serve:  ${lan_info}  |  Proxy: ${proxy_status}" \
      "────────────────────────────────────────")"

    local rc=0 choice=""
    choice="$($DIALOG_CMD --title "TRMNLP-PiServe" \
      --cancel-button "Quit" \
      --menu "$info_text" "$h" "$w" "$mh" \
      "──" "── Plugin Workflow ─────────────────" \
      "1" "Init new plugin" \
      "2" "Clone plugin" \
      "3" "Serve plugin (foreground)" \
      "4" "Serve plugin (background)" \
      "5" "Stop background server" \
      "6" "Push plugin" \
      "──" "── Plugins ────────────────────────" \
      "L" "List plugins" \
      "A" "Login" \
      "──" "── Engine & Updates ───────────────" \
      "E" "Switch engine (gem/repo)" \
      "I" "Engine info" \
      "H" "Update local repo (pull+bundle)" \
      "U" "Rebuild gem from repo" \
      "──" "── PNG Rendering ──────────────────" \
      "N" "Install Firefox Nightly + geckodriver" \
      "T" "Test PNG renderer" \
      "──" "── System ────────────────────────" \
      "S" "Settings" \
      3>&1 1>&2 2>&3)" || rc=$?
    choice="$(trim "$choice")"

    if [[ -z "$choice" || $rc -ne 0 ]]; then
      echo "Bye."; exit 0
    fi

    case "$choice" in
      1) init_plugin ;;
      2) clone_plugin ;;
      3) serve_foreground ;;
      4) serve_daemon ;;
      5) stop_daemon ;;
      6) push_plugin ;;
      L|l) local plugins; plugins="$(get_plugins)"
         if [[ -n "$plugins" ]]; then
           local count; count="$(echo "$plugins" | wc -l)"
           local items=() idx=1
           while IFS= read -r p; do
             items+=("${idx}" "$p")
             ((idx++))
           done <<< "$plugins"
           local lh; lh="$(dlg_h 22)"
           local lw; lw="$(dlg_w 60)"
           local lmh=$(( lh - 8 ))
           (( lmh < 6 )) && lmh=6
           $DIALOG_CMD --title "Plugins (${count} total)" \
             --ok-button "Back" --cancel-button "Back" \
             --menu "$(trunc $(( lw - 6 )) "$BASE_DIR")" \
             "$lh" "$lw" "$lmh" "${items[@]}" 3>&1 1>&2 2>&3 || true
         else
           dialog_msgbox "Plugins" "No plugins found in ${BASE_DIR}" 8 "$(dlg_w 50)"
         fi ;;
      A|a) login_interactive ;;
      E|e) switch_engine ;;
      I|i) show_engine_info ;;
      H|h) update_repo_only_menu ;;
      U|u) update_gem_from_head_menu ;;
      N|n) install_firefox_nightly ;;
      T|t) test_png_renderer ;;
      S|s) change_settings_dialog ;;
      *) continue ;;
    esac
  done
}

main_menu_text(){
  while true; do
    echo ""; bold "==================== TRMNLP-PiServe ====================="
    echo "Plugin root: ${BASE_DIR}"
    echo "Ruby:        $(ruby_version) $(rbenv_active && echo '(rbenv)')"
    echo "Serve:       app on 127.0.0.1:${BIND_PORT}; proxy to LAN: $( [[ "${ENABLE_PROXY}" == "1" ]] && echo 'ENABLED' || echo 'disabled' )"
    echo "Engine:      ${ENGINE}  $( [[ "${ENGINE}" == "repo" ]] && echo "(HEAD $(repo_commit_short) on $(repo_branch))" )"
    echo "---------------------------------------------------------"
    echo "Plugin Workflow:"
    echo "  1) Init new plugin"
    echo "  2) Clone plugin"
    echo "  3) Serve plugin (foreground)"
    echo "  4) Serve plugin (background)"
    echo "  5) Stop background server + proxy"
    echo "  6) Push plugin"
    echo "Plugins:"
    echo "  L) List plugins"
    echo "  A) Login"
    echo "Engine & Updates:"
    echo "  E) Switch engine (gem/repo)"
    echo "  I) Engine info"
    echo "  H) Update local repo (git pull + bundle)"
    echo "  U) Rebuild gem from repo"
    echo "PNG Rendering:"
    echo "  N) Install/Update Firefox Nightly + geckodriver"
    echo "  T) Test PNG renderer"
    echo "System:"
    echo "  S) Settings"
    echo "  0) Exit"
    echo "---------------------------------------------------------"
    read -r -p "Choose: " ch || true
    case "$ch" in
      1) init_plugin ;;
      2) clone_plugin ;;
      3) serve_foreground ;;
      4) serve_daemon ;;
      5) stop_daemon ;;
      6) push_plugin ;;
      L|l) local plugins; plugins="$(get_plugins)"
         if [[ -n "$plugins" ]]; then
           local count; count="$(echo "$plugins" | wc -l)"
           echo ""; bold "Plugins (${count} total) — ${BASE_DIR}"
           echo "$plugins" | nl -ba -w3 -s'  '
           echo ""
         else
           warn "No plugins found in ${BASE_DIR}"
         fi ;;
      A|a) login_interactive ;;
      E|e) switch_engine ;;
      I|i) show_engine_info ;;
      H|h) update_repo_only_menu ;;
      U|u) update_gem_from_head_menu ;;
      N|n) install_firefox_nightly ;;
      T|t) test_png_renderer ;;
      S|s) change_settings ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

# ------------ Help flag ------------
show_help(){
  cat <<'HELP'
TRMNLP-PiServe - TRMNL plugin development manager for Raspberry Pi

Usage:
  ./trmnlp-piserve.sh           Launch the interactive menu
  ./trmnlp-piserve.sh -h        Show this help
  ./trmnlp-piserve.sh --help    Show this help

Menu keys:
  1-6                   Plugin workflow (init, clone, serve, stop, push)
  L = List plugins      A = Login
  E = Switch engine     I = Engine info
  H = Update repo       U = Rebuild gem
  N = Firefox Nightly   T = Test PNG renderer
  S = Settings          0 = Exit

Environment variables:
  ENGINE=gem|repo       Execution engine (default: gem)
  BIND_PORT=4567        Preview server port
  ENABLE_PROXY=1|0      LAN proxy via socat (default: 1)
  PRINT_ONLY=1          Dry-run mode, print commands only
  TRMNLP_TUI=0          Force plain text menus (skip whiptail/dialog)

Settings and secrets are stored in ~/.config/trmnlp-piserve/

See README.md for full documentation.
HELP
}

case "${1:-}" in
  -h|--help) show_help; exit 0 ;;
esac

main_menu
