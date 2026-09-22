#!/bin/sh
# /autorun.sh -- the egg's run.sh executes this on EVERY boot of the VPS.
#   every boot : check GitHub (FCC_Egg repo) for a new version of run.sh + autorun.sh
#                and ask y/n in the console before replacing them
#   first boot : install SSH, nano, Node, pm2, git and Forthway Command Center
#   every boot : make a fresh sign-in PIN for Forthway Command Center, bring FCC back up
#                under pm2, show pm2 list, print the PIN in a box, start SSH

FCC_DIR=/home/container/Forthway-Command-Center   # clone target: the VPS boots with cwd=/home/container (also $HOME)
FCC_NAME=forthway                       # pm2 process name that FCC's install.sh uses

# --- script self-update -------------------------------------------------------
# run.sh, autorun.sh and VERSION live in the FCC_Egg GitHub repo. When VERSION on
# GitHub differs from the version recorded on this VPS, you are asked (y/n) in the
# panel console before /run.sh and /autorun.sh are replaced. Bump VERSION in the
# repo to roll a change out; nothing is replaced without a "y".
FCC_EGG_REPO="${FCC_EGG_REPO:-llallenll/FCC_Egg}"     # GitHub owner/repo holding the scripts
FCC_EGG_REF="${FCC_EGG_REF:-main}"                    # branch (or tag) to follow  -- egg variable "SCRIPTS BRANCH"
FCC_EGG_RAW="${FCC_EGG_RAW:-https://raw.githubusercontent.com/$FCC_EGG_REPO}"   # + /<commit>/<file>
FCC_EGG_API="${FCC_EGG_API:-https://api.github.com}"  # asked for the branch's current commit; also serves the files when FCC_GITHUB_TOKEN is set
FCC_VERSION_FILE=/.fcc-scripts-version                # version currently installed on this VPS
FCC_UPDATE_TIMEOUT="${FCC_UPDATE_TIMEOUT:-60}"        # seconds to wait for y/n (no answer = n); 0 = wait forever  -- egg variable "SCRIPT UPDATE PROMPT TIMEOUT"
FCC_GITHUB_TOKEN="${FCC_GITHUB_TOKEN:-}"              # only needed while the FCC_Egg repo is private  -- egg variable "GITHUB TOKEN"

# --- sign-in PIN --------------------------------------------------------------
# Every start of this server makes a fresh six-character code, writes it where the
# Command Center reads it, and prints it in a box in this console. The code is the
# panel's sign-in credential: whoever can see this console can sign in, and nobody
# else can. It stays the same until the next start of this server, however often
# the panel itself restarts (the file is read at each sign-in, not at start-up).
FCC_PIN_LOGIN="${FCC_PIN_LOGIN:-1}"                   # 1 = sign in with the PIN (default), 0 = with the panel's password  -- egg variable "PIN LOGIN"
FCC_PIN_FILE="${FCC_PIN_FILE:-$FCC_DIR/forthway/hub/data/pin}"   # FCC's install.sh puts the panel in $FCC_DIR/forthway; the panel reads hub/data/pin
FCC_PIN_LENGTH=6
FCC_PIN_CHARS="ABCDEFGHJKMNPQRSTUVWXYZ23456789"        # no 0/O or 1/I/L: the code is read off a screen

fcc_make_pin() {   # sets FCC_PIN: FCC_PIN_LENGTH random characters from FCC_PIN_CHARS
    FCC_PIN=""
    tries=0
    while [ "${#FCC_PIN}" -ne "$FCC_PIN_LENGTH" ] && [ "$tries" -lt 5 ]; do
        FCC_PIN=$(LC_ALL=C tr -dc "$FCC_PIN_CHARS" < /dev/urandom 2>/dev/null | head -c "$FCC_PIN_LENGTH")
        tries=$((tries + 1))
    done
    if [ "${#FCC_PIN}" -ne "$FCC_PIN_LENGTH" ]; then
        # no usable /dev/urandom: awk's generator, seeded from the clock and this pid, is the fallback
        FCC_PIN=$(awk -v n="$FCC_PIN_LENGTH" -v chars="$FCC_PIN_CHARS" -v seed="$(date +%s)$$" \
            'BEGIN { srand(seed); for (i = 0; i < n; i++) printf "%s", substr(chars, int(rand() * length(chars)) + 1, 1) }')
    fi
}

fcc_save_pin() {   # writes FCC_PIN where the Command Center reads it -- or removes it, when PIN sign-in is off
    if [ "$FCC_PIN_LOGIN" != "1" ]; then
        rm -f "$FCC_PIN_FILE"
        return 0
    fi
    mkdir -p "$(dirname "$FCC_PIN_FILE")" || return 1
    # written whole, then renamed: the panel never reads a half-written file
    printf '%s\n' "$FCC_PIN" > "$FCC_PIN_FILE.tmp" && chmod 600 "$FCC_PIN_FILE.tmp" && mv -f "$FCC_PIN_FILE.tmp" "$FCC_PIN_FILE"
}

fcc_print_pin_box() {   # the PIN, in a box, as the last thing printed before SSH starts
    if [ "$FCC_PIN_LOGIN" != "1" ]; then
        echo "[FCC] PIN sign-in is off (PIN LOGIN = $FCC_PIN_LOGIN): the panel asks for its password."
        return 0
    fi
    if [ -t 1 ]; then
        c_box=$(printf '\033[1;33m'); c_title=$(printf '\033[1;97m'); c_pin=$(printf '\033[1;92m')
        c_text=$(printf '\033[37m');   c_warn=$(printf '\033[1;31m');  c_off=$(printf '\033[0m')
    else
        c_box=""; c_title=""; c_pin=""; c_text=""; c_warn=""; c_off=""
    fi
    w=56                                  # inner width; every row is padded to it, so the right edge lines up
    bar=""; i=0
    while [ "$i" -lt "$w" ]; do bar="$bar═"; i=$((i + 1)); done
    row() {   # row TEXT COLOUR  -- one row, TEXT centred (ASCII only: the width maths counts bytes)
        left=$(( (w - ${#1}) / 2 )); right=$(( w - left - ${#1} ))
        printf '  %s║%s%*s%s%s%s%*s%s║%s\n' "$c_box" "$c_off" "$left" "" "$2" "$1" "$c_off" "$right" "" "$c_box" "$c_off"
    }
    spaced=$(printf '%s' "$FCC_PIN" | sed 's/./& /g; s/ $//')
    echo
    printf '  %s╔%s╗%s\n' "$c_box" "$bar" "$c_off"
    row "" ""
    row "Forthway Command Center PIN" "$c_title"
    row "" ""
    row "$spaced" "$c_pin"
    row "" ""
    row "Type this code on the panel's sign-in page." "$c_text"
    row "A new one is made every time this server starts." "$c_text"
    row "" ""
    printf '  %s╚%s╝%s\n' "$c_box" "$bar" "$c_off"
    echo
    # The panel only asks for a PIN from version 2.10.0. A server that took this
    # script update before updating the panel still signs in with its password.
    if [ -f "$FCC_DIR/forthway/hub/server.mjs" ] && ! grep -q 'FCC_PIN_FILE' "$FCC_DIR/forthway/hub/server.mjs"; then
        printf '%s[FCC] The installed Command Center does not use the PIN yet -- it still asks for its password.%s\n' "$c_warn" "$c_off"
        printf '%s[FCC] Update it from the panel (Settings -> Updates); the PIN above works from the next sign-in.%s\n' "$c_warn" "$c_off"
        echo
    fi
}

fcc_get() {   # fcc_get URL DEST ACCEPT  -- one download with curl or wget, whichever is installed (token sent when set)
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$FCC_GITHUB_TOKEN" ]; then
            curl -fsSL --connect-timeout 10 --max-time 60 -H "Accept: $3" -H "Authorization: Bearer $FCC_GITHUB_TOKEN" -o "$2" "$1"
        else
            curl -fsSL --connect-timeout 10 --max-time 60 -H "Accept: $3" -o "$2" "$1"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -n "$FCC_GITHUB_TOKEN" ]; then
            wget -q --timeout=30 --tries=2 --header="Accept: $3" --header="Authorization: Bearer $FCC_GITHUB_TOKEN" -O "$2" "$1"
        else
            wget -q --timeout=30 --tries=2 --header="Accept: $3" -O "$2" "$1"
        fi
    else
        return 1
    fi
}

fcc_resolve_ref() {   # sets fcc_ref (and fcc_desc): the commit $FCC_EGG_REF points at right now, or the branch name if GitHub cannot be asked
    # raw.githubusercontent.com serves a branch's files from a cache that can be up to 5 minutes old, so
    # everything is downloaded by commit id instead (a commit never changes). The API answer is not cached.
    fcc_ref="$FCC_EGG_REF"
    fcc_desc="branch $FCC_EGG_REF"
    if fcc_get "$FCC_EGG_API/repos/$FCC_EGG_REPO/commits/$FCC_EGG_REF" /.fcc-scripts-commit.tmp "application/vnd.github.sha"; then
        sha=$(tr -d '[:space:]' < /.fcc-scripts-commit.tmp)
        case "$sha" in
            *[!0-9a-f]*|"") ;;                                   # not a commit id: keep the branch name
            *) if [ "${#sha}" -eq 40 ]; then
                   fcc_ref="$sha"
                   fcc_desc="branch $FCC_EGG_REF at commit $(printf '%.7s' "$sha")"
               fi ;;
        esac
    fi
    rm -f /.fcc-scripts-commit.tmp
}

fcc_fetch() {   # fcc_fetch FILE DEST  -- download FILE from the FCC_Egg repo at the commit fcc_resolve_ref found
    if [ -n "$FCC_GITHUB_TOKEN" ]; then
        # private repo: the GitHub API hands the raw file to the token's owner
        fcc_get "$FCC_EGG_API/repos/$FCC_EGG_REPO/contents/$1?ref=$fcc_ref" "$2" "application/vnd.github.raw"
    else
        # public repo: raw download by commit id, so no cached copy of the branch can be served
        fcc_get "$FCC_EGG_RAW/$fcc_ref/$1?nocache=$(date +%s)" "$2" "*/*"
    fi
}

fcc_read_answer() {   # read one console line into $answer: 0 = got a line, 1 = no input (EOF), 2 = timed out
    answer=""
    if [ "$FCC_UPDATE_TIMEOUT" -gt 0 ] 2>/dev/null && command -v bash >/dev/null 2>&1; then
        # plain sh cannot time out a read, so let bash do the timed read from the same console stdin
        answer=$(bash -c 'IFS= read -r -t "$1" a; s=$?; [ "$s" -gt 128 ] && exit 2; printf "%s" "$a"; exit "$s"' _ "$FCC_UPDATE_TIMEOUT")
        rc=$?
    else
        IFS= read -r answer
        rc=$?
    fi
    answer=$(printf '%s' "$answer" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    return "$rc"
}

fcc_ask_update() {   # 0 = update now, 1 = not now
    while :; do
        if [ "$FCC_UPDATE_TIMEOUT" -gt 0 ] 2>/dev/null; then
            echo "[FCC] Update run.sh and autorun.sh now? Type y or n in the console (no answer within ${FCC_UPDATE_TIMEOUT}s = n)"
        else
            echo "[FCC] Update run.sh and autorun.sh now? Type y or n in the console"
        fi
        fcc_read_answer
        rc=$?
        if [ "$rc" -eq 2 ]; then
            echo "[FCC] No answer within ${FCC_UPDATE_TIMEOUT}s -- not updating this time."
            return 1
        elif [ "$rc" -ne 0 ]; then
            echo "[FCC] No console input available -- not updating this time."
            return 1
        fi
        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "[FCC] Please answer y or n." ;;
        esac
    done
}

fcc_apply_update() {   # fcc_apply_update NEW_VERSION  -- replaces /run.sh + /autorun.sh, then re-runs autorun.sh
    echo "[FCC] Downloading run.sh and autorun.sh version $1 from GitHub..."
    if ! fcc_fetch run.sh /run.sh.new || ! fcc_fetch autorun.sh /autorun.sh.new; then
        rm -f /run.sh.new /autorun.sh.new
        echo "[FCC] Download failed -- keeping the current scripts. You will be asked again on the next start."
        return 1
    fi
    if ! sh -n /run.sh.new || ! sh -n /autorun.sh.new; then
        rm -f /run.sh.new /autorun.sh.new
        echo "[FCC] The downloaded scripts failed a syntax check -- keeping the current scripts."
        return 1
    fi
    cp -f /run.sh /run.sh.bak 2>/dev/null
    cp -f /autorun.sh /autorun.sh.bak 2>/dev/null
    chmod +x /run.sh.new /autorun.sh.new
    # mv here is a rename: the run.sh that is executing right now keeps running from
    # its old copy, and the new run.sh is picked up on the next start of the server.
    mv -f /run.sh.new /run.sh
    mv -f /autorun.sh.new /autorun.sh
    printf '%s\n' "$1" > "$FCC_VERSION_FILE"
    echo "[FCC] Scripts updated to version $1 (previous copies: /run.sh.bak and /autorun.sh.bak)."
    echo "[FCC] Starting the new autorun.sh (the new run.sh is used from the next start)..."
    export FCC_UPDATED=1
    exec sh /autorun.sh
}

fcc_check_for_updates() {
    if [ "${FCC_UPDATED:-0}" = "1" ]; then
        return 0                              # this is the freshly updated autorun.sh re-running itself: no second check
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "[FCC] Script update check skipped: curl/wget are not installed yet."
        return 0
    fi
    fcc_resolve_ref
    echo "[FCC] Checking GitHub ($FCC_EGG_REPO, $fcc_desc) for script updates..."
    if [ "$fcc_ref" = "$FCC_EGG_REF" ]; then
        echo "[FCC] (could not ask GitHub for the branch's latest commit -- a copy up to 5 minutes old may be served)"
    fi
    if ! fcc_fetch VERSION /.fcc-scripts-version.remote; then
        rm -f /.fcc-scripts-version.remote
        echo "[FCC] Script update check skipped: could not download VERSION from GitHub."
        return 0
    fi
    new_ver=$(tr -d '[:space:]' < /.fcc-scripts-version.remote)
    rm -f /.fcc-scripts-version.remote
    cur_ver=$(cat "$FCC_VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$new_ver" in
        ""|*[!A-Za-z0-9._-]*)
            echo "[FCC] Script update check skipped: VERSION on GitHub is not a valid version string."
            return 0 ;;
    esac
    if [ "$new_ver" = "$cur_ver" ]; then
        echo "[FCC] Scripts are up to date (version $cur_ver)."
        return 0
    fi
    echo "[FCC] New scripts on GitHub: version ${cur_ver:-unknown} -> $new_ver (this replaces /run.sh and /autorun.sh)."
    if fcc_ask_update; then
        fcc_apply_update "$new_ver"           # on success this starts the new autorun.sh and never returns
    else
        echo "[FCC] Not updating now. You will be asked again on the next start."
    fi
}

fcc_check_for_updates

# --- the sign-in PIN for this boot ------------------------------------------
fcc_make_pin

# --- first boot: install everything ----------------------------------------
if [ ! -e /.setup-done ]; then
    export DEBIAN_FRONTEND=noninteractive

    echo "[FCC] Installing SSH, please wait..."
    apt-get update -qq
    apt-get install -y -qq wget curl ca-certificates
    arch=$(uname -m)
    case "$arch" in
      x86_64)  ssh_arch=amd64 ;;
      aarch64) ssh_arch=arm64 ;;
      *) echo "unsupported arch $arch" ;;
    esac
    wget -q -O /usr/local/bin/ssh \
      "https://github.com/ysdragon/ssh/releases/latest/download/ssh-$ssh_arch"
    chmod +x /usr/local/bin/ssh

# The egg's "SSH PORT" variable is named port2 (lowercase); PORT2 is kept for setups that use it.
cat > /ssh_config.yml <<INNER
ssh:
  port: "${PORT2:-${port2:-2222}}"
  user: "root"
  password: "${SSH_PASSWORD:-password}"

sftp:
  enable: true
INNER

    clear
    echo "[FCC] Installing NANO, please wait..."
    apt-get install -y -qq nano

    clear
    echo "[FCC] Installing NODE & NPM, please wait..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
    apt-get install -y -qq nodejs

    clear
    echo "[FCC] Installing PM2, please wait..."
    npm install -g pm2

    clear
    echo "[FCC] Installing GIT, please wait..."
    apt-get install -y -qq git

    clear
    echo "[FCC] Installing Forthway Command Center, please wait..."
    git clone https://github.com/llallenll/Forthway-Command-Center "$FCC_DIR"
    # The PIN goes in before the panel's first start, so it never asks anyone to
    # choose a password. install.sh leaves hub/data alone.
    fcc_save_pin
    # FCC's install.sh starts the "forthway" pm2 process and runs `pm2 save`;
    # that saved list is what `pm2 resurrect` brings back on later boots.
    (cd "$FCC_DIR" && bash install.sh)

    clear
    touch /.setup-done
    echo "[FCC] Dependencies installed."
else
    # Restart / reboot: the pm2 daemon died with the container, so restore the
    # saved process list. If the saved list is missing, start FCC directly.
    echo "[FCC] Starting Forthway Command Center..."
    fcc_save_pin                # this boot's PIN, in place before the panel comes back
    pm2 resurrect --silent      # --silent: the `pm2 list` further down prints the process table once
    if ! pm2 describe "$FCC_NAME" >/dev/null 2>&1; then
        (cd "$FCC_DIR/forthway" && SERVER_PORT="${SERVER_PORT:-4000}" \
            pm2 start hub/server.mjs --name "$FCC_NAME" --time --update-env) && pm2 save
    fi
fi

# --- runs on every boot ---
pm2 list
fcc_print_pin_box
/usr/local/bin/ssh
