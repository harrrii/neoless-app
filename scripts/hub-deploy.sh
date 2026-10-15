#!/bin/bash
# Deploys neoless-hub on this Mac (the "Neo"): release build, copy to ~/Applications/neoless-hub,
# and three LaunchAgents: the ASR worker, the hub, and a Cloudflare tunnel of its own.
# Safe to re-run. It only touches its own three LaunchAgents and its own tunnel config.
#
#   scripts/hub-deploy.sh              build + install + (re)load the three services
#   scripts/hub-deploy.sh --no-build   install the last release build
#   scripts/hub-deploy.sh --dry-run    say what it would do and check what it would install, changing nothing:
#                                      no build, no copy, no LaunchAgent, no launchctl, no Cloudflare, no network
#
# Any other argument is refused before anything happens.
#
# Settings come from the environment, or from local/hub.env (untracked; start from hub/hub.env.example):
#   NEOLESS_HUB_HOST       required: the hostname your tunnel answers on, e.g. hub.example.com
#   NEOLESS_TUNNEL         the tunnel's name (default: neoless)
#   NEOLESS_LABEL_PREFIX   the LaunchAgents are <prefix>-asr, <prefix>-hub, <prefix>-tunnel
#                          (default: the prefix of the ones already installed, else app.neoless)
#   NEOLESS_ASR_PYTHON     the Python that runs the ASR worker (default: a venv this script makes in
#                          ~/Applications/neoless-hub/asr/.venv from hub/asr/requirements.txt)
#   NEOLESS_BUILD_WRAPPER  a command to run the build under (a build lock, nice, …); default: none
#   NEOLESS_ASR_MODEL      another pinned model for the worker (hub/asr/README.md); default: Qwen3-ASR-0.6B-4bit
#   NEOLESS_ASR_FALLBACK_MODEL  a second, smaller pinned model: NEOLESS_ASR_MODEL is then the "large" one and this
#                          the "small" one a device can ask for, and the one that stands in while the large one is
#                          too slow for this Mac. Default: none (one model).
#   NEOLESS_ASR_KEEP_DIR   opt-in: the worker also saves each recording into this folder (the newest 20, for 7 days),
#                          to compare models on your own voice. Unset (the default): no recording is kept.
#
# One-time Cloudflare setup (after `cloudflared tunnel login`), with your own hostname:
#   cloudflared tunnel create neoless
#   cloudflared tunnel route dns neoless hub.example.com
# Then docs/hub.md, "Access 双重锁", to put Cloudflare Access in front of it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD=1
DRY=0
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "不认识的选项 $arg（可以用 --no-build、--dry-run）" >&2; exit 2 ;;
    esac
done

# local/hub.env: KEY=VALUE lines; what the environment already sets wins. A leading ~/ means the home folder.
LOCAL="${NEOLESS_LOCAL:-$ROOT/local}"
if [[ -f "$LOCAL/hub.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then continue; fi
        if [[ ! "$line" =~ ^[[:space:]]*(NEOLESS_[A-Z_]+)=(.*)$ ]]; then
            echo "$LOCAL/hub.env 里这一行看不懂：$line" >&2
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
        if [[ "$value" == "~/"* ]]; then value="$HOME/${value#\~/}"; fi
        if [[ -z "${!key:-}" ]]; then export "$key=$value"; fi
    done < "$LOCAL/hub.env"
fi

HOST="${NEOLESS_HUB_HOST:-}"
if [[ -z "$HOST" ]]; then
    echo "还不知道 Hub 对外的域名。在 local/hub.env 里写 NEOLESS_HUB_HOST=你的域名（照 hub/hub.env.example），" >&2
    echo "或者这样运行：NEOLESS_HUB_HOST=hub.example.com scripts/hub-deploy.sh" >&2
    exit 1
fi
if [[ ! "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$HOST" != *.* ]]; then
    echo "NEOLESS_HUB_HOST 只写域名，不带 https:// 和路径：$HOST" >&2
    exit 1
fi
TUNNEL="${NEOLESS_TUNNEL:-neoless}"
HUB_PORT=18800
ASR_PORT=18801
INSTALL="$HOME/Applications/neoless-hub"
DATA="$HOME/Library/Application Support/neoless-hub"
AGENTS="$HOME/Library/LaunchAgents"
CLOUDFLARED="$(command -v cloudflared || echo /opt/homebrew/bin/cloudflared)"

# The LaunchAgents' labels. A hub deployed before keeps the labels it has: a second set would fight over the ports.
PREFIX="${NEOLESS_LABEL_PREFIX:-}"
if [[ -z "$PREFIX" ]]; then
    found=""
    count=0
    for file in "$AGENTS"/*neoless-hub.plist; do
        [[ -f "$file" ]] || continue
        name="$(basename "$file" .plist)"
        found="$found ${name%-hub}"
        count=$((count + 1))
    done
    if (( count == 1 )); then
        PREFIX="${found# }"
    elif (( count > 1 )); then
        echo "~/Library/LaunchAgents 里有不止一套 neoless-hub 的启动项（$found ）。" >&2
        echo "在 local/hub.env 里用 NEOLESS_LABEL_PREFIX 写明用哪一套，另一套自己停掉。" >&2
        exit 1
    else
        PREFIX="app.neoless"
    fi
fi
if [[ ! "$PREFIX" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "NEOLESS_LABEL_PREFIX 只能有字母、数字、点和连字符：$PREFIX" >&2
    exit 1
fi

# The worker's Python: yours, or a venv of the worker's own next to the installed worker.
PYTHON="${NEOLESS_ASR_PYTHON:-}"
OWN_VENV=0
if [[ -z "$PYTHON" ]]; then
    PYTHON="$INSTALL/asr/.venv/bin/python"
    OWN_VENV=1
fi
WRAPPER=()
if [[ -n "${NEOLESS_BUILD_WRAPPER:-}" ]]; then read -r -a WRAPPER <<< "$NEOLESS_BUILD_WRAPPER"; fi

plist_file() { # dir, label, log name, program args (one per line), env (KEY=VALUE per line): writes <dir>/<label>.plist
    local dir="$1" label="$2" log="$3" args="$4" env="$5" file="$1/$2.plist"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        echo "  <key>Label</key><string>$label</string>"
        echo '  <key>ProgramArguments</key><array>'
        while IFS= read -r a; do [[ -n "$a" ]] && echo "    <string>$a</string>"; done <<< "$args"
        echo '  </array>'
        if [[ -n "$env" ]]; then
            echo '  <key>EnvironmentVariables</key><dict>'
            while IFS='=' read -r k v; do [[ -n "$k" ]] && echo "    <key>$k</key><string>$v</string>"; done <<< "$env"
            echo '  </dict>'
        fi
        echo '  <key>RunAtLoad</key><true/>'
        echo '  <key>KeepAlive</key><true/>'
        echo '  <key>ThrottleInterval</key><integer>10</integer>'
        echo '  <key>ProcessType</key><string>Interactive</string>'
        echo "  <key>WorkingDirectory</key><string>$INSTALL</string>"
        echo "  <key>StandardOutPath</key><string>$INSTALL/logs/$log.log</string>"
        echo "  <key>StandardErrorPath</key><string>$INSTALL/logs/$log.log</string>"
        echo '</dict></plist>'
    } > "$file.new" && mv -f "$file.new" "$file"
}

ASR_ARGS="$PYTHON
$INSTALL/asr/asr_worker.py
--port
$ASR_PORT"
ASR_ENV="PYTHONUNBUFFERED=1
HF_HUB_OFFLINE=1
HF_HUB_DISABLE_TELEMETRY=1${NEOLESS_ASR_MODEL:+
NEOLESS_ASR_MODEL=$NEOLESS_ASR_MODEL}${NEOLESS_ASR_FALLBACK_MODEL:+
NEOLESS_ASR_FALLBACK_MODEL=$NEOLESS_ASR_FALLBACK_MODEL}${NEOLESS_ASR_KEEP_DIR:+
NEOLESS_ASR_KEEP_DIR=$NEOLESS_ASR_KEEP_DIR}"
HUB_ARGS="$INSTALL/bin/neoless-hub
serve
--port
$HUB_PORT"
TUNNEL_ARGS="$CLOUDFLARED
--config
$DATA/cloudflared.yml
tunnel
run
$TUNNEL"

run() {
    if (( DRY )); then
        printf '（演练）会运行：'; printf '%q ' "$@"; printf '\n'
    else
        "$@"
    fi
}

echo "域名：$HOST；隧道：$TUNNEL；启动项：$PREFIX-asr、$PREFIX-hub、$PREFIX-tunnel"
echo "安装到：$INSTALL；数据：$DATA；worker 的 Python：$PYTHON"
echo "识别模型：${NEOLESS_ASR_MODEL:-默认（Qwen3-ASR-0.6B-4bit）}；小模型：${NEOLESS_ASR_FALLBACK_MODEL:-没有配}；另存录音：${NEOLESS_ASR_KEEP_DIR:-不保存}"

if (( BUILD )); then
    run ${WRAPPER[@]+"${WRAPPER[@]}"} swift build -c release --product neoless-hub
fi
if (( DRY )); then
    BIN="$ROOT/.build/release/neoless-hub"
else
    BIN="$(swift build -c release --show-bin-path)/neoless-hub"
    [[ -x "$BIN" ]] || { echo "没有找到 $BIN，先编译（去掉 --no-build）" >&2; exit 1; }
fi

if (( DRY )); then
    echo "（演练）会把 neoless-hub 和 asr_worker.py 装到 $INSTALL，并把数据文件夹设成只有你能读"
else
    mkdir -p "$INSTALL/bin" "$INSTALL/asr" "$INSTALL/logs"
    mkdir -p "$DATA" && chmod 700 "$DATA"
    # Copy then rename, so a running process keeps its old file until it restarts.
    cp "$BIN" "$INSTALL/bin/neoless-hub.new" && mv -f "$INSTALL/bin/neoless-hub.new" "$INSTALL/bin/neoless-hub"
    cp hub/asr/asr_worker.py "$INSTALL/asr/asr_worker.py.new" && mv -f "$INSTALL/asr/asr_worker.py.new" "$INSTALL/asr/asr_worker.py"
    git rev-parse --short HEAD > "$INSTALL/VERSION" 2>/dev/null || true
fi

# The worker's own venv, made once: mlx, mlx-audio and what they need (a few hundred MB from PyPI).
if (( OWN_VENV )) && [[ ! -x "$PYTHON" ]]; then
    # The worker's packages (numpy, scipy) need Python 3.12 or newer; the python3 of the Command Line Tools is 3.9.
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
        echo "语音识别 worker 需要 Python 3.12 以上，现在的 python3 是：$(python3 --version 2>&1 || echo 没有找到)。" >&2
        echo "装一个新的（比如 brew install python）再运行；或者在 local/hub.env 里用 NEOLESS_ASR_PYTHON 指定一个已经装好依赖的 Python。" >&2
        exit 1
    fi
    echo "给语音识别 worker 建 Python 环境（第一次要下载几百 MB 的依赖）：$INSTALL/asr/.venv"
    run python3 -m venv "$INSTALL/asr/.venv"
    run "$PYTHON" -m pip install --upgrade pip
    run "$PYTHON" -m pip install -r hub/asr/requirements.txt
fi
if (( ! DRY )); then
    [[ -x "$PYTHON" ]] || { echo "没有找到 worker 的 Python：$PYTHON" >&2; exit 1; }
    # The models must already be in the Hugging Face cache: the worker never downloads.
    # A local model folder needs no download; a pinned model id must be in the cache.
    check_model() { # a model id, or nothing for the default one
        local model="$1"
        local -a model_args=()
        if [[ -n "$model" && -d "$model" ]]; then return 0; fi
        if [[ -n "$model" ]]; then model_args=(--model "$model"); fi
        if ! "$PYTHON" hub/asr/fetch_model.py --check ${model_args[@]+"${model_args[@]}"} >/dev/null 2>&1; then
            echo "识别模型还没下载。先运行（默认的模型约 1.3 GB，只这一次联网）：" >&2
            echo "  $PYTHON hub/asr/fetch_model.py ${model_args[*]-}" >&2
            echo "下载好再重新运行这个脚本。" >&2
            exit 1
        fi
    }
    check_model "${NEOLESS_ASR_MODEL:-}"
    if [[ -n "${NEOLESS_ASR_FALLBACK_MODEL:-}" ]]; then check_model "$NEOLESS_ASR_FALLBACK_MODEL"; fi
fi

# Your own instructions for the polish, if you keep some in local/ (docs/hub.md, "自己改整理指令").
for name in polish-natural.md polish-structured.md; do
    [[ -f "$LOCAL/$name" ]] || continue
    if (( DRY )); then
        echo "（演练）会把 $LOCAL/$name 复制到数据文件夹：听写用你这份指令"
    else
        cp "$LOCAL/$name" "$DATA/$name.new" && chmod 600 "$DATA/$name.new" && mv -f "$DATA/$name.new" "$DATA/$name"
        echo "整理指令：用你自己的 $name"
    fi
done

if (( DRY )); then
    echo "（演练）会向 Cloudflare 查隧道 $TUNNEL 的 ID，写 $DATA/cloudflared.yml：$HOST 的 /v1/ → 127.0.0.1:$HUB_PORT，其余 404"
    echo "（演练）会写并重新加载 $AGENTS 里的 $PREFIX-asr.plist、$PREFIX-hub.plist、$PREFIX-tunnel.plist"
    echo "（演练）会记下对外地址：$INSTALL/bin/neoless-hub server https://$HOST"
    # Checks what would be installed. Reads this checkout only; writes nothing but a temporary folder it removes.
    problems=0
    CHECK_PYTHON="$PYTHON"
    if [[ ! -x "$CHECK_PYTHON" ]]; then CHECK_PYTHON="$(command -v python3 || true)"; fi
    if [[ -n "$CHECK_PYTHON" ]]; then
        # Compiled in memory: no __pycache__ is written.
        if "$CHECK_PYTHON" -I -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' hub/asr/asr_worker.py; then
            echo "  ✓ asr_worker.py 语法正确（worker $(sed -n "s/^VERSION = '\(.*\)'/\1/p" hub/asr/asr_worker.py)）"
        else
            echo "  ✗ asr_worker.py 有语法错误" >&2; problems=1
        fi
    else
        echo "  · 没有找到 Python，没检查 asr_worker.py"
    fi
    if [[ -x "$CLOUDFLARED" ]]; then echo "  ✓ cloudflared：$CLOUDFLARED"; else echo "  · 没有找到 cloudflared（真部署时会停下）"; fi
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/neoless-hub-deploy-dry.XXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    plist_file "$scratch" "$PREFIX-asr" asr "$ASR_ARGS" "$ASR_ENV"
    plist_file "$scratch" "$PREFIX-hub" hub "$HUB_ARGS" ""
    plist_file "$scratch" "$PREFIX-tunnel" tunnel "$TUNNEL_ARGS" ""
    for file in "$scratch"/*.plist; do
        if plutil -lint -s "$file"; then echo "  ✓ $(basename "$file") 格式正确"; else echo "  ✗ $(basename "$file") 格式不对" >&2; problems=1; fi
    done
    if (( problems )); then echo "演练结束：什么也没改，但上面有要先解决的问题。" >&2; exit 1; fi
    echo "演练结束：什么也没改。"
    exit 0
fi

[[ -x "$CLOUDFLARED" ]] || { echo "没有找到 cloudflared：先安装（brew install cloudflared），再 cloudflared tunnel login" >&2; exit 1; }
TUNNEL_ID="$("$CLOUDFLARED" tunnel list --output json 2>/dev/null \
    | "$PYTHON" -I -c 'import json,sys; t=[x["id"] for x in json.load(sys.stdin) if x["name"]==sys.argv[1]]; print(t[0] if t else "")' "$TUNNEL")"
[[ -n "$TUNNEL_ID" ]] || { echo "Cloudflare 隧道 $TUNNEL 不存在：先运行 cloudflared tunnel create $TUNNEL" >&2; exit 1; }
cat > "$DATA/cloudflared.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $HOME/.cloudflared/$TUNNEL_ID.json
metrics: 127.0.0.1:18809
no-autoupdate: true
ingress:
  - hostname: $HOST
    path: ^/v1/
    service: http://127.0.0.1:$HUB_PORT
    originRequest:
      connectTimeout: 10s
  - service: http_status:404
EOF
chmod 600 "$DATA/cloudflared.yml"

plist() { # label, log name, program args (one per line), env (KEY=VALUE per line)
    local label="$1" file="$AGENTS/$1.plist"
    plist_file "$AGENTS" "$@"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    # bootout returns before launchd has let go of the label; bootstrapping too early fails with 5.
    for _ in $(seq 1 50); do launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break; sleep 0.2; done
    launchctl bootstrap "gui/$(id -u)" "$file" || { sleep 2; launchctl bootstrap "gui/$(id -u)" "$file"; }
}

mkdir -p "$AGENTS"
plist "$PREFIX-asr" asr "$ASR_ARGS" "$ASR_ENV"
plist "$PREFIX-hub" hub "$HUB_ARGS" ""
plist "$PREFIX-tunnel" tunnel "$TUNNEL_ARGS" ""

# So `neoless-hub pair` knows the address to put into pairing links.
"$INSTALL/bin/neoless-hub" server "https://$HOST" || true

sleep 3
echo "已部署 $(cat "$INSTALL/VERSION" 2>/dev/null)：https://$HOST → 127.0.0.1:$HUB_PORT"
curl -s -m 5 "http://127.0.0.1:$HUB_PORT/v1/ping" && echo
"$INSTALL/bin/neoless-hub" status --port "$HUB_PORT" || true
echo "接下来：$INSTALL/bin/neoless-hub login（登录 ChatGPT），再 $INSTALL/bin/neoless-hub pair --name <设备名>"
