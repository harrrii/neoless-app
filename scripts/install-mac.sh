#!/bin/bash
# 一条命令把 neoless 装到这台 Mac（Apple 芯片）。在 neoless 的 git 克隆里运行：
#
#   scripts/install-mac.sh                    检查、签名证书、构建并安装到 /Applications，然后打开
#   scripts/install-mac.sh --dry-run          只说会做什么，什么也不改
#   scripts/install-mac.sh --import-openless  另外把 OpenLess 里对学习有用的数据（历史、词典、纠错规则）
#                                             只读地复制到个人文件夹的 neoless-openless-samples/<时间>/
#                                             （不在桌面和文稿，iCloud 不同步它），供你自己 AirDrop 到 Neo
#   scripts/install-mac.sh --no-install       只做检查（和 --import-openless）：不更新代码、不构建、不安装
#
# 可以重复运行：已有的签名证书、已经移走的旧版都会跳过。不会改 OpenLess 的任何设置。
set -Eeuo pipefail

# App 的 bundle id（scripts/app-id.sh）：已经装着 neoless 1.0 以上时沿用它的，这样更新后权限、设置和配对都还在；
# 第一次装用 Resources/Info.plist 里的。main 里才算，因为要先知道克隆在哪。
BUNDLE_ID=""
# 这几个路径可以用环境变量换掉，只为了在别的文件夹里试这个脚本（平时不用设）。
APP="${NEOLESS_INSTALL_APP:-/Applications/neoless.app}"
IDENTITY="neoless Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENLESS_APP="${NEOLESS_INSTALL_OPENLESS_APP:-/Applications/OpenLess.app}"
OPENLESS_DATA="${NEOLESS_INSTALL_OPENLESS_DATA:-$HOME/Library/Application Support/OpenLess}"
# OpenLess（Tauri 版，app identifier com.openless.app）在 macOS 上的数据，见 src-tauri/src/persistence 和
# crates/openless-core：history.json（听写历史：原文和整理后的文字）、dictionary.json（个人词典）、
# correction-rules.json（纠错规则）、vocab-presets.json（词库预设）。只复制这几个；登录凭据和密钥
# （credentials.json、credentials.enc.json、sync-secrets/、remote-tls-identity-v1.json、~/.openless/）、
# 偏好设置、录音和模型一概不碰。
OPENLESS_FILES=(history.json dictionary.json correction-rules.json vocab-presets.json)
# 个人文件夹本身：不在 iCloud 的“桌面与文稿”同步里，也不用给终端开桌面的访问权限。
SAMPLES="${NEOLESS_INSTALL_SAMPLES:-$HOME/neoless-openless-samples}"
OLD_DIR="${NEOLESS_INSTALL_OLD_DIR:-$HOME/Applications}"
# 编译 neoless 的依赖（Hummingbird、SwiftNIO…）要 Swift 6.1；Swift 6.1 的 Command Line Tools 要 macOS 15.2。
MIN_SWIFT="6.1"
MIN_MACOS_FOR_SWIFT="15.2"

DRY_RUN=0
IMPORT=0
INSTALL=1
# The Command Line Tools are there (git and swift work). Only a dry run goes on without them.
TOOLS=1
# Where this run put the OpenLess copy (empty: nothing copied).
IMPORTED=""
# Where this run moved the old app, while the new one is not installed yet (empty: nothing moved).
OLD_MOVED_TO=""
# … and once the new one is.
OLD_MOVED_TO_DONE=""

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '注意：%s\n' "$*"; }
# 旧版挪走了还没装好新版时，说一下旧版在哪、怎么换回去。
old_app_hint() {
    [[ -n "$OLD_MOVED_TO" ]] || return 0
    printf '旧版 neoless 在 %s：要先用回旧版，在访达里把它改名去掉末尾的 .bak，拖回「应用程序」。\n' "$OLD_MOVED_TO" >&2
}
die() {
    printf '没有完成：%s\n' "$*" >&2
    old_app_hint
    exit 1
}

# 没料到的出错（set -e 让脚本停下的那种）也用中文说一句，不只留下英文的报错。
on_error() {
    local status="$1" line="$2" command="$3"
    # 命令替换 $(…) 里的出错由外面那一层来说，不说两遍。
    (( BASH_SUBSHELL == 0 )) || return 0
    printf '\n没有完成：第 %s 行的命令出错了（%s，退出码 %s），上面是详细信息。\n' "$line" "$command" "$status" >&2
    printf '可以直接重新运行（做完的步骤会跳过）；还不行，就把这个窗口里的文字整个复制下来，找人帮忙看。\n' >&2
    old_app_hint
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# 改动系统的命令都经过这里：演练时只打印。
run() {
    if (( DRY_RUN )); then
        printf '（演练）会运行：'; printf '%q ' "$@"; printf '\n'
    else
        "$@"
    fi
}

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

parse() {
    while (( $# )); do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --import-openless) IMPORT=1 ;;
            --no-install) INSTALL=0 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "不认识的选项 $1" ;;
        esac
        shift
    done
}

# 版本号 $1 不低于 $2（都是 主.次[.修订]）。
at_least() {
    local IFS=.
    local -a have want
    read -r -a have <<< "$1"
    read -r -a want <<< "$2"
    local i h w
    for i in 0 1 2; do
        h="${have[i]:-0}"; w="${want[i]:-0}"
        h="${h//[!0-9]/}"; w="${w//[!0-9]/}"
        if (( 10#${h:-0} > 10#${w:-0} )); then return 0; fi
        if (( 10#${h:-0} < 10#${w:-0} )); then return 1; fi
    done
    return 0
}

# MARK: 检查

check_machine() {
    step "检查这台 Mac"
    (( EUID != 0 )) || die "不要用 sudo 运行，用你自己的账号直接运行 scripts/install-mac.sh"
    # 在 Rosetta 下运行的终端里 uname -m 会说 x86_64，所以问硬件本身。
    [[ "$(sysctl -in hw.optional.arm64 2>/dev/null)" == "1" ]] || die "neoless 只支持 Apple 芯片（M1 及以后）的 Mac"
    local version
    version="$(sw_vers -productVersion)"
    at_least "$version" 14 || die "需要 macOS 14 或更新，这台是 $version"
    say "Apple 芯片，macOS $version：可以"
    # 「应用程序」只有管理员能写：普通账号要到最后才会失败，所以先看。
    local apps
    apps="$(dirname "$APP")"
    if [[ ! -w "$apps" ]]; then
        local why="这个账号不能往「应用程序」（$apps）里装 App（多半不是管理员账号）。请用管理员账号运行，或先向 IT 临时要管理员权限，再重新运行"
        if (( DRY_RUN )); then warn "$why"; else die "$why"; fi
    fi
}

# "Apple Swift version 6.1 (swiftlang-…)" → 6.1
swift_version() {
    local out re='Swift version ([0-9]+(\.[0-9]+)*)'
    out="$(xcrun swift -version 2>&1 || true)"
    if [[ $out =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

check_tools() {
    if ! { xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; }; then
        TOOLS=0
        say "这台 Mac 还没有 Command Line Tools（编译 neoless 要用，不需要完整的 Xcode；安装要管理员账号）。"
        say "马上会弹出系统的安装窗口：点「安装」，等它装完（几分钟），再重新运行 scripts/install-mac.sh。"
        run xcode-select --install || true
        # 演练时接着说后面会做什么；真运行时没有它就编译不了。
        (( DRY_RUN )) || exit 1
        return
    fi
    local swift macos developer
    swift="$(swift_version)"
    macos="$(sw_vers -productVersion)"
    developer="$(xcode-select -p 2>/dev/null || true)"
    [[ -n "$swift" ]] || die "读不出 Swift 的版本（xcrun swift -version 没有说）。重新装一次 Command Line Tools：xcode-select --install"
    if at_least "$swift" "$MIN_SWIFT"; then
        say "开发工具：Swift $swift（$developer）：可以"
        return
    fi
    if ! at_least "$macos" "$MIN_MACOS_FOR_SWIFT"; then
        die "编译 neoless 要 Swift $MIN_SWIFT 或更新（这台是 Swift $swift），它只能装在 macOS $MIN_MACOS_FOR_SWIFT 或更新上（这台是 $macos）。先在 系统设置 › 通用 › 软件更新 把 macOS 升级，再重新运行"
    fi
    if [[ "$developer" == *.app/* ]]; then
        die "现在用的是 Xcode 里的 Swift $swift，太旧（要 $MIN_SWIFT 或更新）。把 Xcode 更新到 16.3 或更新，或者改用 Command Line Tools：sudo xcode-select -s /Library/Developer/CommandLineTools，再重新运行"
    fi
    die "Command Line Tools 太旧（Swift $swift，要 $MIN_SWIFT 或更新）。打开 系统设置 › 通用 › 软件更新，装“Command Line Tools for Xcode”的更新（没看到就在终端运行 softwareupdate --list 看一下），装完再重新运行"
}

# Package.resolved 是构建算出来的：新版 Swift 会多记几个依赖，改动它不算你的改动。
resolved_changed() { ! git diff --quiet -- Package.resolved 2>/dev/null; }

restore_resolved() {
    (( TOOLS )) || return 0
    if resolved_changed; then run git checkout --quiet -- Package.resolved; fi
}

check_checkout() {
    if (( ! TOOLS )); then
        say "（演练）还没有 Command Line Tools，git 也用不了：跳过“代码是不是最新”的检查"
        return
    fi
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$ROOT 不是 neoless 的 git 克隆。按 README 的“安装”先 git clone，再运行 ~/neoless/scripts/install-mac.sh"
    local branch dirty
    branch="$(git symbolic-ref --quiet --short HEAD || echo '(没有分支)')"
    dirty="$(git status --porcelain --untracked-files=no -- . ':(exclude)Package.resolved' | cut -c4-)"
    if [[ -n "$dirty" ]]; then
        say "这个文件夹里有改过、还没提交的文件："
        while IFS= read -r name; do say "  $name"; done <<< "$dirty"
        die "先把这些改动收起来：git -C \"$ROOT\" stash（不会丢，git -C \"$ROOT\" stash pop 能拿回来），再重新运行"
    fi
    if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        warn "分支 $branch 没有跟踪远端，跳过“是不是最新”的检查"
        return
    fi
    if (( DRY_RUN )); then
        say "（演练）不联网 fetch，只和上次 fetch 到的远端比较"
    # 不在中途停下来问 GitHub 的用户名和密码：登录过的（钥匙串里有令牌）照常能用。
    elif ! GIT_TERMINAL_PROMPT=0 git fetch --quiet 2>/dev/null; then
        warn "连不上 GitHub，没能检查更新；用现在这份代码继续"
    fi
    local behind ahead
    behind="$(git rev-list --count 'HEAD..@{u}')"
    ahead="$(git rev-list --count '@{u}..HEAD')"
    if (( behind == 0 )); then
        say "代码：已是最新（$branch，$(git rev-parse --short HEAD)）"
        return
    fi
    (( ahead == 0 )) || die "本地分支 $branch 和远端分叉了（本地多 $ahead 个提交、远端多 $behind 个），先自己处理好；没有自己的改动的话，重新 git clone 一份最省事"
    if (( ! INSTALL )); then
        say "代码：远端有 $behind 个新提交。按 --no-install 不更新；去掉 --no-install 再运行，就会先更新"
        return
    fi
    say "代码：远端有 $behind 个新提交，先更新"
    # 上次构建改过的 Package.resolved 会挡住 git pull：它反正会重新生成。
    restore_resolved
    if (( DRY_RUN )); then
        run git pull --ff-only
        return
    fi
    GIT_TERMINAL_PROMPT=0 git pull --ff-only --quiet \
        || die "没能把代码更新到最新（上面是 git 的原因）。网络好了再重新运行"
    # 这个脚本自己也可能更新了：用新的那份重新开始（只一次）。
    [[ -z "${NEOLESS_INSTALL_UPDATED:-}" ]] || return 0
    say "已更新到 $(git rev-parse --short HEAD)，用新的安装脚本重新开始"
    NEOLESS_INSTALL_UPDATED=1 exec "$ROOT/scripts/install-mac.sh" "${ARGS[@]+"${ARGS[@]}"}"
}

# MARK: OpenLess 数据（可选）

import_openless() {
    step "复制 OpenLess 的学习数据（只读）"
    if [[ ! -d "$OPENLESS_DATA" ]]; then
        say "没找到 $OPENLESS_DATA，跳过（这台 Mac 上没有用过 OpenLess？）"
        return
    fi
    local found=()
    local name
    for name in "${OPENLESS_FILES[@]}"; do
        # 只要普通文件，不跟随链接。
        if [[ -f "$OPENLESS_DATA/$name" && ! -L "$OPENLESS_DATA/$name" ]]; then found+=("$name"); fi
    done
    if (( ${#found[@]} == 0 )); then
        say "$OPENLESS_DATA 里没有历史、词典或纠错规则，跳过"
        return
    fi
    local dest
    dest="$SAMPLES/$(date +%Y-%m-%d-%H%M%S)"
    say "会复制到 $dest（只有你能读）："
    for name in "${found[@]}"; do say "  $name（$(du -h "$OPENLESS_DATA/$name" | cut -f1 | tr -d ' ')）"; done
    if (( DRY_RUN )); then
        run mkdir -p "$dest"
        for name in "${found[@]}"; do run cp "$OPENLESS_DATA/$name" "$dest/$name"; done
        IMPORTED="$dest"
        return
    fi
    (umask 077 && mkdir -p "$dest")
    chmod 700 "$SAMPLES" "$dest"
    for name in "${found[@]}"; do
        cp "$OPENLESS_DATA/$name" "$dest/$name"
        chmod 600 "$dest/$name"
    done
    cat > "$dest/说明.txt" <<EOF
这些是 OpenLess 在这台 Mac 上的数据副本（$(date '+%Y-%m-%d %H:%M') 复制，原文件没有改动）：
$(for name in "${found[@]}"; do printf '  %s\n' "$name"; done)
history.json 是听写历史（原文和整理后的文字），dictionary.json 是个人词典，correction-rules.json 是纠错规则，
vocab-presets.json 是词库预设。没有复制登录凭据、API 密钥、偏好设置和录音。

这个文件夹在你的个人文件夹里（访达 › 前往 › 个人），不在桌面和文稿，所以 iCloud 的“桌面与文稿”不会同步它，
安装脚本也没有上传它。备份软件如果备份整个个人文件夹，会把它一起备份。要给 Neo 学习用，自己用 AirDrop
发到 Neo；用完后在两台电脑上都删掉它（里面有你说过的话）。
EOF
    chmod 600 "$dest/说明.txt"
    # 复制的只是历史、词典和规则；万一里面混进了像密钥的文字，提醒一下。
    local hits
    hits="$( { grep -lE 'sk-[A-Za-z0-9_-]{20,}|"(api[_-]?key|apiKey|secret|password)"[[:space:]]*:' "$dest"/*.json 2>/dev/null || true; } \
        | while IFS= read -r file; do printf '%s ' "$(basename "$file")"; done)"
    if [[ -n "$hits" ]]; then
        warn "副本里有像 API 密钥或密码的文字（${hits% }），发给 Neo 之前打开看一下"
    fi
    IMPORTED="$dest"
    say "已复制到 $dest。iCloud 不同步这里，脚本也没有上传；要用时自己 AirDrop 到 Neo。"
}

# MARK: 签名证书

# 只补上“信任它用于代码签名”这一步（上次在确认弹窗里点了取消时）。
trust_identity() {
    if (( DRY_RUN )); then
        run security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "<“$IDENTITY”的证书>"
        return 0
    fi
    local pem status=0
    pem="$(mktemp -t neoless-cert)" || return 1
    if security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$pem" 2>/dev/null && [[ -s "$pem" ]]; then
        security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem" || status=1
    else
        status=1
    fi
    rm -f "$pem"
    return "$status"
}

ensure_signing() {
    step "签名证书"
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
        say "已有“$IDENTITY”：以后更新 neoless 不用重新给权限"
        return
    fi
    if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
        warn "钥匙串里已经有“$IDENTITY”证书，但还没被信任（上次可能在确认弹窗里点了取消）。"
        say "现在只补上“信任”这一步：macOS 会弹窗请你确认（输入登录密码或用触控 ID）。"
        if trust_identity; then
            say "已信任“$IDENTITY”：以后更新 neoless 不用重新给权限"
        else
            warn "没信任成功（又点了取消？）。照样继续：签名用不了它时会自动改用临时签名（那样以后更新要重新给权限）；再运行这个脚本会再试"
        fi
        return
    fi
    say "neoless 要用一个只在这台 Mac 上的签名证书（“$IDENTITY”），这样以后更新 neoless，"
    say "macOS 不会要你重新允许麦克风、语音识别和辅助功能。现在创建它（scripts/make-signing-identity.sh）："
    say "  · macOS 会弹窗请你确认信任这个证书（输入登录密码或用触控 ID），只信任它用于代码签名、只对你的账号；"
    say "  · 如果「登录」钥匙串锁着，还会请你输入钥匙串密码（一般就是开机密码）；"
    say "  · 之后第一次构建时，可能弹窗问 codesign 能不能使用这个密钥：输入登录密码，点「始终允许」。"
    say "  不想要它：打开「钥匙串访问」（用 Spotlight 搜），在 登录 里删掉“$IDENTITY”的证书和密钥即可。"
    if ! run "$ROOT/scripts/make-signing-identity.sh"; then
        warn "没创建好签名证书（可能在弹窗里点了取消）。照样继续：签名用不了它时会自动改用临时签名（那样以后更新要重新给权限）；再运行这个脚本会再试"
    fi
}

# MARK: 构建（先构建，成功了才动已装的 neoless）

build_app() {
    step "构建"
    say "第一次构建要下载依赖、编译几分钟。这一步不动已经装好的 neoless。"
    if ! run "$ROOT/scripts/build-app.sh"; then
        restore_resolved
        die "构建没成功（上面是详细信息），已经装好的 neoless 没动。可以直接重新运行；还不行，就把这个窗口里的文字整个复制下来，找人帮忙看"
    fi
}

# MARK: 旧版 neoless

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

move_old_app() {
    step "旧版 neoless"
    if [[ ! -e "$APP" ]]; then
        say "还没装过 neoless（$APP），直接安装"
        return
    fi
    local id version
    id="$(plist_value "$APP" CFBundleIdentifier)"
    version="$(plist_value "$APP" CFBundleShortVersionString)"
    if [[ "$id" == "$BUNDLE_ID" && "$version" != 0.* && -n "$version" ]]; then
        say "已装的是 neoless $version，安装时直接换成新构建"
        return
    fi
    # 改成 .bak：访达里显示成文件夹，Spotlight 和链接都不会再打开它；改回 .app 就能用。
    local target
    target="$OLD_DIR/neoless-old-$(date +%Y-%m-%d)"
    if [[ -e "$target.app.bak" ]]; then target="$target-$(date +%H%M%S)"; fi
    target="$target.app.bak"
    say "已装的是旧版（${id:-没有 bundle id} ${version:-没有版本号}）：不删除，挪到 $target"
    # 正在运行的话先让它自己退出，免得它和新版同时抢 Fn。只看从这个位置运行的进程，也不会因此把它打开。
    if pgrep -f "^$APP/" >/dev/null 2>&1; then
        say "旧版正在运行，先让它退出"
        if (( DRY_RUN )); then
            run osascript -e "tell application id \"$id\" to quit"
        else
            if [[ -n "$id" ]]; then osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true; fi
            local _
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                pgrep -f "^$APP/" >/dev/null 2>&1 || break
                sleep 0.5
            done
            if pgrep -f "^$APP/" >/dev/null 2>&1; then die "旧版 neoless 还在运行：从它的菜单栏图标退出，再重新运行"; fi
        fi
    fi
    run mkdir -p "$OLD_DIR"
    if ! run mv "$APP" "$target"; then
        die "没能挪走 $APP。可能是这个账号不是管理员，或者「终端」没有“App 管理”权限（系统设置 › 隐私与安全性 › App 管理，打开「终端」）。处理好再重新运行"
    fi
    if (( ! DRY_RUN )); then OLD_MOVED_TO="$target"; fi
    say "要换回旧版：退出新版 neoless，在访达里把 $target 改名去掉末尾的 .bak，拖回「应用程序」。"
    say "旧版要是设了登录时打开，到 系统设置 › 通用 › 登录项 里把它去掉。"
    local agents
    # Neo 上 Hub 自己的启动项（neoless-hub / -asr / -tunnel）不算。
    agents="$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -i neoless | grep -v -e neoless-hub -e neoless-asr -e neoless-tunnel | tr '\n' ' ' || true)"
    if [[ -n "$agents" ]]; then
        warn "~/Library/LaunchAgents 里有旧版留下的启动项：$agents。新版不需要它们，确认是旧版的就删掉（这个脚本不动它们）"
    fi
}

# MARK: OpenLess

warn_openless() {
    [[ -d "$OPENLESS_APP" ]] || return 0
    step "OpenLess"
    say "这台 Mac 上有 OpenLess，它也用 Fn 听写，两个一起开会抢同一个键。"
    say "neoless 不会改 OpenLess 的任何设置。测试 neoless 之前，请你自己二选一："
    say "  · 在 OpenLess 的设置里把听写快捷键换成别的键；或者"
    say "  · 退出 OpenLess（菜单栏图标 › 退出）。"
    say "（也可以反过来：在 neoless 的 设置 › 快捷键 › 按键 里换成右侧 Option 或右侧 Command。）"
    # 进程名可能是 OpenLess 或 openless：按 App 的路径找，不分大小写。
    if pgrep -if '/OpenLess\.app/' >/dev/null 2>&1; then
        say "OpenLess 现在正在运行。"
        if (( ! DRY_RUN )) && [[ -t 0 ]]; then
            local reply
            read -r -p "先退出 OpenLess 或换掉它的快捷键，然后按回车继续…" reply || true
        fi
    fi
}

# MARK: 安装

install_app() {
    step "安装"
    say "装进 $(dirname "$APP") 并打开 neoless（已经在运行的会先退出；刚才构建好了，这一步很快）。"
    if ! run "$ROOT/scripts/build-app.sh" --install; then
        restore_resolved
        die "构建好了，但没能装进「应用程序」（上面是原因）。常见原因：「终端」没有“App 管理”权限（系统设置 › 隐私与安全性 › App 管理，打开「终端」），或这个账号不是管理员。处理好再重新运行"
    fi
    OLD_MOVED_TO_DONE="$OLD_MOVED_TO"
    OLD_MOVED_TO=""
    # 构建可能改写了 Package.resolved（新版 Swift 多记几个依赖）：还原，下次更新不会被它挡住。
    restore_resolved
}

next_steps() {
    step "接下来"
    cat <<EOF
1. 权限：neoless 打开后，听写页会列出还差的步骤。点「允许」给 麦克风 和 语音识别，
   再到 系统设置 › 隐私与安全性 › 辅助功能 打开 neoless（快捷键、Esc 和自动输入都要它）。
   那里如果已经有 neoless 而且开着，neoless 却仍说没有权限（旧版留下的那一条）：
   选中它点「−」删掉，回到 neoless 再点「允许」，打开新出现的开关。
   离线识别模型和 🌐 键的设置，听写页也会提示。
2. 钥匙串：如果弹窗问 neoless 能不能使用钥匙串里的“$BUNDLE_ID.hub”（以前配对过、
   这次签名变了时会出现），输入登录密码，点「始终允许」。那里存着和 Neo 的配对；
   点了「拒绝」的话，设置里会显示还没配对。
3. 和 Neo 配对（可选；不配对也能用，那样识别和整理都在这台 Mac 上）：Neo 是你自己那台跑着
   neoless-hub 的 Mac（怎么搭见 docs/hub.md）。在 Neo 上（终端）运行
     ~/Applications/neoless-hub/bin/neoless-hub pair --name "我的 Mac"
   用 AirDrop 或通用剪贴板把它打印的 neoless://pair?… 链接传到这台 Mac。别用备忘录和信息：
   它们会同步到 iCloud，删掉的备忘录还会在“最近删除”里留 30 天，而链接里有密钥。
   粘贴到 neoless 的 设置 › Neo 处理中心 › 配对，点「配对」。Neo 开了双重锁时，链接里自带
   Cloudflare 门禁凭据，配好后“双重锁”一行显示“已开启”。
4. 如果用 OpenLess：先换掉它的快捷键或退出它，再按 Fn 试 neoless。
EOF
    local n=5
    if [[ -n "$OLD_MOVED_TO_DONE" ]]; then
        say "$n. 旧版 neoless 在 $OLD_MOVED_TO_DONE：新版用着没问题就可以删掉它。"
        n=$((n + 1))
    fi
    if [[ -n "$IMPORTED" ]]; then
        say "$n. OpenLess 的数据副本在 $IMPORTED，自己 AirDrop 到 Neo；用完删掉。"
    fi
}

main() {
    ARGS=("$@")
    parse "$@"
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    cd "$ROOT"
    [[ -x scripts/build-app.sh && -x scripts/make-signing-identity.sh && -x scripts/app-id.sh ]] \
        || die "$ROOT 不像 neoless 的克隆（缺 scripts/build-app.sh）"
    BUNDLE_ID="$(NEOLESS_INSTALL_APP="$APP" scripts/app-id.sh)" || die "算不出 App 的 bundle id（上面是原因）"
    if (( DRY_RUN )); then say "演练：只说会做什么，不改这台 Mac 上的任何东西。"; fi

    check_machine
    check_tools
    check_checkout
    if (( IMPORT )); then import_openless; fi
    if (( ! INSTALL )); then
        say ""
        say "按 --no-install，没有更新代码、没有构建和安装。"
        return
    fi
    ensure_signing
    build_app
    move_old_app
    warn_openless
    install_app
    next_steps
    if (( DRY_RUN )); then say ""; say "演练结束：什么也没改。去掉 --dry-run 就会真的做。"; fi
}

# 整个脚本读完才开始运行：更新代码时改到这个文件本身也不会出错。
main "$@"
