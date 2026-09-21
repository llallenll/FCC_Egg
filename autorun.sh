#!/bin/sh
# /autorun.sh -- the egg's run.sh executes this on EVERY boot of the VPS.
#   every boot : check GitHub (FCC_Egg repo) for a new version of run.sh + autorun.sh
#                and ask y/n in the console before replacing them
#   first boot : install SSH, nano, Node, pm2, git and Forthway Command Center
#   every boot : bring Forthway Command Center back up under pm2, show pm2 list, start SSH

FCC_DIR=/home/container/Forthway-Command-Center   # clone target: the VPS boots with cwd=/home/container (also $HOME)
FCC_NAME=forthway                       # pm2 process name that FCC's install.sh uses

# --- script self-update -------------------------------------------------------
# run.sh, autorun.sh and VERSION live in the FCC_Egg GitHub repo. When VERSION on
# GitHub differs from the version recorded on this VPS, you are asked (y/n) in the
# panel console before /run.sh and /autorun.sh are replaced. Bump VERSION in the
# repo to roll a change out; nothing is replaced without a "y".
FCC_EGG_REPO="${FCC_EGG_REPO:-llallenll/FCC_Egg}"     # GitHub owner/repo holding the scripts
FCC_EGG_REF="${FCC_EGG_REF:-main}"                    # branch (or tag) to follow  -- egg variable "SCRIPTS BRANCH"
FCC_EGG_RAW="${FCC_EGG_RAW:-https://raw.githubusercontent.com/$FCC_EGG_REPO/$FCC_EGG_REF}"
FCC_VERSION_FILE=/.fcc-scripts-version                # version currently installed on this VPS
FCC_UPDATE_TIMEOUT="${FCC_UPDATE_TIMEOUT:-60}"        # seconds to wait for y/n (no answer = n); 0 = wait forever  -- egg variable "SCRIPT UPDATE PROMPT TIMEOUT"

fcc_fetch() {   # fcc_fetch URL FILE  -- download with curl or wget, whichever is installed
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 -o "$2" "$1?nocache=$(date +%s)"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=2 -O "$2" "$1?nocache=$(date +%s)"
    else
        return 1
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
    if ! fcc_fetch "$FCC_EGG_RAW/run.sh" /run.sh.new || ! fcc_fetch "$FCC_EGG_RAW/autorun.sh" /autorun.sh.new; then
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
    echo "[FCC] Checking GitHub ($FCC_EGG_REPO, branch $FCC_EGG_REF) for script updates..."
    if ! fcc_fetch "$FCC_EGG_RAW/VERSION" /.fcc-scripts-version.remote; then
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
    pm2 resurrect
    if ! pm2 describe "$FCC_NAME" >/dev/null 2>&1; then
        (cd "$FCC_DIR/forthway" && SERVER_PORT="${SERVER_PORT:-4000}" \
            pm2 start hub/server.mjs --name "$FCC_NAME" --time --update-env) && pm2 save
    fi
fi

# --- runs on every boot ---
pm2 list
/usr/local/bin/ssh
