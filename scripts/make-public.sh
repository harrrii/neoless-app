#!/bin/bash
# Exports the public tree of this repository into an empty folder.
#
#   scripts/make-public.sh <target folder> [--commit <message file>] [--onto <public clone>] [--allow-dirty]
#                          [--no-private-checks]
#
# The author keeps a private checkout with things that must never be published next to this code (their own
# dictation samples and recordings, working notes, deployment settings). The public repository is that checkout
# minus those files. This script makes it, and is careful about it:
#
#   1. Only tracked files on the ALLOWLIST below are copied. Anything new stays private until it is added here.
#   2. The result is then searched, and the export is refused (and removed) if it holds
#      - something that looks like a secret, a personal path or a real e-mail address (the patterns below);
#      - any of the private words in local/forbidden-patterns.txt (untracked: the list itself is private),
#        except on the lines local/allowed-hits.txt names (a listed word that is also an ordinary entry of one of
#        the code's general word lists);
#      - both sides of a row of the private corrections list (samples/corrections.json), or a misrecognition of
#        the private dictionary (samples/vocabulary.json, misheard_as) and its term, on one line, unless
#        local/allowed-pairs.txt names the pair: two harmless words can together be a line of private data;
#      - a stretch of text copied from the private text folders (samples/, and those local/private-sources.txt
#        names): any run of $NGRAM Chinese characters or more that also occurs there.
#   3. It prints every file it exported.
#   4. With --commit, it makes the target a git repository with one commit, and nothing personal in that commit:
#      - the message is the file you give, searched like the exported files;
#      - the author is $NEOLESS_PUBLIC_AUTHOR, which must be the GitHub no-reply address of the account that
#        publishes, with its numeric id: "login <12345+login@users.noreply.github.com>" (the id is public:
#        https://api.github.com/users/<login>). A plain "name@users.noreply.github.com" belongs to whoever has
#        that login, so GitHub would show the commit as somebody else's;
#      - the dates are written in UTC, so the commit does not say which time zone it was made in;
#      - a pre-push hook that refuses to push into a repository holding commits this one does not have.
#   5. With --commit and --onto <public clone>, a LATER export becomes the next commit of the public repository
#      instead of a new history: the checked export replaces the files of that clone (a clean checkout of the
#      public repository, never of the private one) and is committed there the same way. People who cloned the
#      public repository can then update with a plain pull (scripts/install-mac.sh does that), which a history
#      started afresh would break. The target folder is emptied again afterwards.
#
# Publishing: the first time, push the target to a BRAND-NEW repository; later, export with --onto and push that
# clone. Never push a branch of the private repository, never add the private repository as a remote of the
# target, and never switch the private repository to public: its history and its other branches hold the
# private files, and a forced push does not take them back.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
LOCAL="${NEOLESS_LOCAL:-$ROOT/local}"
NGRAM="${NEOLESS_PUBLIC_NGRAM:-7}"

# ---------------------------------------------------------------- allowlist

# Exact files.
FILES=(
    .gitignore LICENSE NOTICE CREDITS.md README.md Package.swift Package.resolved
    Resources/Info.plist Resources/neoless.icns Resources/icon/draw-icon.swift Resources/icon/neoless-1024.png
    docs/DESIGN.md docs/hub.md
    examples/README.md examples/vocabulary.example.json examples/corrections.example.json
    examples/polish-eval.example.json
    hub/hub.env.example
    hub/asr/.gitignore hub/asr/README.md hub/asr/requirements.txt
    hub/asr/asr_worker.py hub/asr/compare.py hub/asr/fetch_model.py hub/asr/smoke.py hub/asr/test_asr_worker.py
    screenshots/overview-dark.png screenshots/overview-light.png screenshots/dictionary-habits.png
    screenshots/settings-model.png screenshots/history.png screenshots/capsule-recording.png
    screenshots/capsule-hold.png screenshots/capsule-polishing.png screenshots/capsule-noted.png
    screenshots/settings-local.png screenshots/how-it-works.svg
    scripts/app-id.sh scripts/build-app.sh scripts/hub-deploy.sh scripts/install-mac.sh scripts/make-public.sh
    scripts/make-signing-identity.sh scripts/snapshot.sh scripts/typecheck-ios.sh
)
# Folders of source code: every tracked file with this extension below them.
TREES=( "Sources:swift" "Tests:swift" )

# Lines the public .gitignore gets on top of the shared one: nobody's dictation data belongs in the public tree.
PUBLIC_IGNORES='
# Dictation samples, recordings and evaluation results are private: never commit them here.
samples/
neoless-openless-samples/
tune-eval/
*.wav
*.m4a
*.caf
*.aiff'

# ---------------------------------------------------------------- what must not be in the result

# name<TAB>extended regular expression (case-sensitive). A match that is, as a whole, one of ALLOWED is let through.
HOME_FOLDER='/(Users|home)/[A-Za-z0-9._-]+'
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
GENERIC=$'a user\'s home folder\t'"$HOME_FOLDER"$'
a Cloudflare Access client secret\tcfast_[A-Za-z0-9]{8,}
a Cloudflare Access client id\t[0-9a-f]{32}\\.access
a Cloudflare Access team domain\t[A-Za-z0-9-]+\\.cloudflareaccess\\.com
a private key\tBEGIN [A-Z ]*PRIVATE KEY
a GitHub token\t(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}
an OpenAI key\tsk-[A-Za-z0-9_-]{20,}
a JSON Web Token\teyJ[A-Za-z0-9_-]{20,}\\.eyJ[A-Za-z0-9_-]{20,}
an e-mail address\t'"$EMAIL"
# What the patterns above may match: placeholders and documentation. Each match is looked at by itself and must be
# one of these as a whole, so a placeholder does not let a real address or folder on the same line through.
ALLOWED='0123456789abcdef0123456789abcdef\.access|example\.cloudflareaccess\.com|[A-Za-z0-9._%+-]+@(example\.(com|cn|org|net)|[bc]\.com|users\.noreply\.github\.com)|/Users/(you|me|name)'
# The co-author line of a commit message may hold this address, and no other line may.
CO_AUTHOR='^Co-Authored-By: [^<>]*<noreply@anthropic\.com>$'
# No audio at all, and nothing that is not plain text or one of the pictures on the list.
AUDIO='\.(wav|m4a|caf|aiff?|mp3|flac|ogg|opus)$'

# ---------------------------------------------------------------- arguments

TARGET=""
ALLOW_DIRTY=0
PRIVATE_CHECKS=1
COMMIT=0
MESSAGE=""
ONTO=""
USAGE="usage: scripts/make-public.sh <target folder> [--commit <message file>] [--onto <public clone>] [--allow-dirty] [--no-private-checks]"
while (( $# )); do
    arg="$1"; shift
    case "$arg" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --no-private-checks) PRIVATE_CHECKS=0 ;;
        --commit) (( $# )) || { echo "--commit needs the file with the commit message" >&2; exit 2; }
                  COMMIT=1; MESSAGE="$1"; shift ;;
        --onto) (( $# )) || { echo "--onto needs the clone of the public repository" >&2; exit 2; }
                ONTO="$1"; shift ;;
        -h|--help) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) if [[ -n "$TARGET" ]]; then echo "one target folder, please" >&2; exit 2; fi; TARGET="$arg" ;;
    esac
done
[[ -n "$TARGET" ]] || { echo "$USAGE" >&2; exit 2; }

fail() { echo "make-public: $*" >&2; exit 1; }
if [[ -n "$ONTO" ]]; then
    (( COMMIT )) || fail "--onto goes with --commit: the export becomes the next commit of that clone"
    [[ -d "$ONTO/.git" ]] || fail "--onto: $ONTO is not a git checkout"
    ONTO="$(cd "$ONTO" && pwd)"
fi

# The commit's author: a GitHub no-reply address with the account's id, and nothing else.
AUTHOR_NAME=""; AUTHOR_EMAIL=""
if (( COMMIT )); then
    [[ -f "$MESSAGE" && -s "$MESSAGE" ]] || fail "no commit message in $MESSAGE"
    MESSAGE="$(cd "$(dirname "$MESSAGE")" && pwd)/$(basename "$MESSAGE")"
    author_form='^([A-Za-z0-9][A-Za-z0-9-]*) <([0-9]+\+([A-Za-z0-9][A-Za-z0-9-]*)@users\.noreply\.github\.com)>$'
    [[ "${NEOLESS_PUBLIC_AUTHOR:-}" =~ $author_form ]] || fail "set NEOLESS_PUBLIC_AUTHOR to the publishing account's GitHub no-reply identity,
like: login <12345+login@users.noreply.github.com> (the number is the account's public id). Nothing else is accepted,
so that no real name or address gets into the commit."
    AUTHOR_NAME="${BASH_REMATCH[1]}"; AUTHOR_EMAIL="${BASH_REMATCH[2]}"
    [[ "$AUTHOR_NAME" == "${BASH_REMATCH[3]}" ]] || fail "NEOLESS_PUBLIC_AUTHOR: the name ($AUTHOR_NAME) must be the login in the address (${BASH_REMATCH[3]})"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "run it in a git checkout: only tracked files are exported"
if (( ! ALLOW_DIRTY )) && [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    fail "the checkout has uncommitted changes; commit them first (or pass --allow-dirty to export the files as they are)"
fi
if [[ -e "$TARGET" ]]; then
    [[ -d "$TARGET" ]] || fail "$TARGET is not a folder"
    [[ -z "$(ls -A "$TARGET")" ]] || fail "$TARGET is not empty; the export starts from an empty folder"
fi
PATTERNS="$LOCAL/forbidden-patterns.txt"
ALLOWED_HITS="$LOCAL/allowed-hits.txt"
if (( PRIVATE_CHECKS )); then
    [[ -f "$PATTERNS" ]] || fail "no $PATTERNS: without the list of private words the result cannot be checked.
Write one (a word or phrase per line; 're:' starts an extended regular expression; '#' a comment),
or pass --no-private-checks if this checkout has nothing private in it."
    command -v python3 >/dev/null 2>&1 || fail "python3 is needed for the copied-text check"
fi

# ---------------------------------------------------------------- export

LIST="$(mktemp -t neoless-public)"
REPORT="$(mktemp -t neoless-public)"
trap 'rm -f "$LIST" "$REPORT"' EXIT

for file in "${FILES[@]}"; do
    git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 || fail "on the allowlist but not tracked here: $file"
    printf '%s\n' "$file" >> "$LIST"
done
for tree in "${TREES[@]}"; do
    folder="${tree%%:*}"; extension="${tree##*:}"
    git -c core.quotepath=false ls-files -- "$folder" | while IFS= read -r file; do
        if [[ "$file" == *."$extension" ]]; then
            printf '%s\n' "$file" >> "$LIST"
        else
            echo "not exported (in $folder/, but not a .$extension file): $file" >&2
        fi
    done
done
sort -u -o "$LIST" "$LIST"

PARENT="$(cd "$(dirname "$TARGET")" 2>/dev/null && pwd)" || fail "the folder that is to hold $TARGET does not exist"
TARGET="$PARENT/$(basename "$TARGET")"
case "$TARGET/" in "$ROOT"/*) fail "the target must be outside this checkout" ;; esac
if [[ -n "$ONTO" ]]; then
    case "$ONTO/" in "$ROOT"/*|"$TARGET"/*) fail "--onto: the public clone must be outside this checkout and the target" ;; esac
    # The clone must be a public export: clean, on a branch, and sharing no commit with this private repository.
    [[ -z "$(git -C "$ONTO" status --porcelain --ignored)" ]] || fail "--onto: $ONTO has changes or untracked files; it must be a clean clone"
    git -C "$ONTO" symbolic-ref --quiet HEAD >/dev/null || fail "--onto: $ONTO is not on a branch"
    while IFS= read -r sha; do
        git cat-file -e "$sha^{commit}" 2>/dev/null && fail "--onto: $ONTO holds commit $sha of this private repository; it is not a public clone"
    done < <(git -C "$ONTO" rev-list --all)
fi
mkdir -p "$TARGET"
while IFS= read -r file; do
    [[ -f "$file" && ! -L "$file" ]] || fail "not a regular file: $file"
    mkdir -p "$TARGET/$(dirname "$file")"
    cp -p "$file" "$TARGET/$file"
done < "$LIST"
printf '%s\n' "$PUBLIC_IGNORES" >> "$TARGET/.gitignore"
# The commit message is published too: it sits in the target while the checks run, and is taken out before the commit.
MESSAGE_COPY=".neoless-commit-message"
if (( COMMIT )); then cp "$MESSAGE" "$TARGET/$MESSAGE_COPY"; fi

# ---------------------------------------------------------------- checks

refuse() {
    echo >&2
    echo "make-public: REFUSED. The export held something it must not; $TARGET was emptied again." >&2
    cat "$REPORT" >&2
    find "$TARGET" -mindepth 1 -delete
    exit 1
}

cd "$TARGET"
found=0

# 1. File names and kinds.
while IFS= read -r file; do
    if printf '%s\n' "$file" | grep -qiE "$AUDIO"; then echo "audio file: $file" >> "$REPORT"; found=1; fi
done < "$LIST"
if [[ -e .git ]]; then echo "a .git folder" >> "$REPORT"; found=1; fi

# 2. Generic patterns: secrets, personal paths, real addresses.
# Prints the lines of grep -n (file:line:text) on stdin that hold a match of the pattern $1 that is not, as a
# whole, one of ALLOWED: every match on a line is looked at, not the line.
unallowed() {
    local line text match
    while IFS= read -r line; do
        text="${line#*:}"; text="${text#*:}"
        while IFS= read -r match; do
            [[ -z "$match" || "$match" =~ ^($ALLOWED)$ ]] && continue
            [[ "$match" =~ ^noreply@anthropic\.com$ && "$text" =~ $CO_AUTHOR ]] && continue
            printf '%s\n' "$line"
            break
        done < <(printf '%s\n' "$text" | grep -oE -e "$1" || true)
    done
}
# The filter itself, on lines it must catch (1, 2, 5: a real address or folder beside a placeholder, a real address
# in a co-author line) and lines it must let through. Written in pieces so that this file passes its own check.
at='@' users='/Users/'
caught="$( { printf '%s\n' "./a:1:write to someone${at}realmail.net, not foo${at}example.com" \
                         "./a:2:Co-Authored-By: someone${at}realmail.net <noreply${at}anthropic.com>" \
                         "./a:3:foo${at}example.com, x${at}b.com and 12+name${at}users.noreply.github.com" \
                         "./a:4:Co-Authored-By: Claude Opus 5.5 <noreply${at}anthropic.com>" | unallowed "$EMAIL"
              printf '%s\n' "./a:5:${users}realname/x and ${users}you/y" "./a:6:${users}you/x, ${users}me and ${users}name/z" \
                  | unallowed "$HOME_FOLDER"; } | cut -d: -f2 | tr '\n' ' ')"
[[ "$caught" == "1 2 5 " ]] || fail "the check for addresses and home folders is broken: of its test lines it caught ${caught:-nothing }instead of 1 2 5"
while IFS=$'\t' read -r name pattern; do
    [[ -n "$name" ]] || continue
    hits="$(grep -rnIE -e "$pattern" . 2>/dev/null | unallowed "$pattern" || true)"
    if [[ -n "$hits" ]]; then
        { echo "$name:"; printf '%s\n' "$hits" | cut -c1-240 | sed 's/^/    /'; } >> "$REPORT"
        found=1
    fi
done <<< "$GENERIC"

# 3. The private word list, in file contents and in file names.
if (( PRIVATE_CHECKS )); then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == re:* ]]; then
            hits="$( { grep -rnIiE -e "${line#re:}" . 2>/dev/null; grep -iE -e "${line#re:}" "$LIST"; } || true)"
        else
            hits="$( { grep -rnIiF -e "$line" . 2>/dev/null; grep -iF -e "$line" "$LIST"; } || true)"
        fi
        # local/allowed-hits.txt: word<TAB>file<TAB>text. A hit for that word in that file is let through when
        # its line holds that text (no backslashes in it), and only then.
        if [[ -n "$hits" && -f "$ALLOWED_HITS" ]]; then
            while IFS=$'\t' read -r word file text || [[ -n "$word" ]]; do
                [[ "$word" == "$line" && -n "$file" && -n "$text" ]] || continue
                hits="$(printf '%s\n' "$hits" | awk -v p="./$file:" -v t="$text" '!(index($0, p) == 1 && index($0, t) > 0)' || true)"
            done < "$ALLOWED_HITS"
        fi
        if [[ -n "$hits" ]]; then
            { echo "private word ($line):"; printf '%s\n' "$hits" | cut -c1-240 | sed 's/^/    /'; } >> "$REPORT"
            found=1
        fi
    done < "$PATTERNS"

    # 3b. A private correction as a pair: both sides of a row of samples/corrections.json, or a word the private
    # dictionary (samples/vocabulary.json) says was misheard and the term it was misheard for, on one line. Each
    # side may be an everyday word that the list above lets through; together they are a line of the private
    # data. local/allowed-pairs.txt (wrong<TAB>right) names the pairs that are common knowledge and may stay.
    if [[ -f "$ROOT/samples/corrections.json" || -f "$ROOT/samples/vocabulary.json" ]]; then
        python3 -I - "$ROOT/samples/corrections.json" "$ROOT/samples/vocabulary.json" "$TARGET" "$LOCAL/allowed-pairs.txt" \
            >> "$REPORT" <<'PY' || found=1
import json, os, re, sys

source, dictionary, target, allowed_file = sys.argv[1:5]
rows = []
if os.path.isfile(source):
    data = json.load(open(source, encoding='utf-8'))
    listed = data.get('corrections', []) if isinstance(data, dict) else data
    rows += [(row.get('wrong', ''), row.get('right', '')) for row in listed if isinstance(row, dict)]
    if isinstance(data, dict):
        rows += [(row.get('heard', ''), row.get('likely', '')) for row in data.get('unfixed_suspects', []) if isinstance(row, dict)]
# The dictionary's misrecognitions: what the user's dictation was heard as, each with its term. (Its aliases are
# other spellings and transliterations, many from a built-in pack: they say nothing about anyone's dictation.)
if os.path.isfile(dictionary):
    vocabulary = json.load(open(dictionary, encoding='utf-8'))
    terms = vocabulary.get('terms', []) if isinstance(vocabulary, dict) else vocabulary
    for term in terms:
        if isinstance(term, dict) and isinstance(term.get('term'), str):
            rows += [(heard, term['term']) for heard in term.get('misheard_as') or [] if isinstance(heard, str)]

allowed = set()
if os.path.isfile(allowed_file):
    for line in open(allowed_file, encoding='utf-8'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) == 2 and not line.startswith('#'):
            allowed.add((parts[0].strip().lower(), parts[1].strip().lower()))


def finder(word):
    """The word as a whole: Latin letters around a Latin word make it another word."""
    edge = lambda c: r'(?<![a-z])' if c.isascii() and c.isalpha() else ''
    tail = lambda c: r'(?![a-z])' if c.isascii() and c.isalpha() else ''
    return re.compile(edge(word[0]) + re.escape(word) + tail(word[-1]))


pairs = []
for wrong, right in rows:
    for w in re.split(r'\s*/\s*', wrong):
        for r in re.split(r'\s*/\s*', right):
            w, r = w.strip().lower(), r.strip().lower()
            if len(w) >= 2 and len(r) >= 2 and w != r and (w, r) not in allowed:
                pairs.append((finder(w), finder(r)))

hits = 0
for folder, _, names in os.walk(target):
    for name in names:
        path = os.path.join(folder, name)
        try:
            text = open(path, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(text.split('\n'), 1):
            low = line.lower()
            if any(w.search(low) and r.search(low) for w, r in pairs):
                hits += 1
                # The pair itself is private: only where it stands is printed.
                print(f'both sides of a private correction on one line: {os.path.relpath(path, target)}:{number}')
sys.exit(1 if hits else 0)
PY
    fi

    # 4. Text copied from the private folders.
    SOURCES=()
    [[ -d "$ROOT/samples" ]] && SOURCES+=("$ROOT/samples")
    if [[ -f "$LOCAL/private-sources.txt" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" == "~/"* ]] && line="$HOME/${line#\~/}"
            [[ "$line" == /* ]] || line="$ROOT/$line"
            [[ -e "$line" ]] || { echo "private source not found: $line" >> "$REPORT"; found=1; continue; }
            SOURCES+=("$line")
        done < "$LOCAL/private-sources.txt"
    fi
    if (( ${#SOURCES[@]} )); then
        ALLOWED_OVERLAPS="$LOCAL/allowed-overlaps.txt"
        python3 -I - "$NGRAM" "$TARGET" "$ALLOWED_OVERLAPS" "${SOURCES[@]}" >> "$REPORT" <<'PY' || found=1
import json, os, re, sys

n, target, allowed_file, sources = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
han = re.compile(r'[\u3400-\u9fff]')


def letters(text):
    """Chinese characters, letters and digits only, so punctuation and spacing do not hide a copy."""
    return re.sub(r'[^0-9A-Za-z\u3400-\u9fff]', '', text)


def files(path):
    if os.path.isfile(path):
        yield path
        return
    for folder, _, names in os.walk(path):
        for name in names:
            yield os.path.join(folder, name)


def read(path):
    try:
        with open(path, encoding='utf-8') as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError):
        return None   # not text (a recording, a picture)


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def pieces(path):
    """The file's text, piece by piece. JSON may write Chinese as \\uXXXX: its strings are read, not its bytes."""
    text = read(path)
    if text is None:
        return []
    if path.endswith('.json'):
        try:
            return list(strings(json.loads(text)))
        except ValueError:
            pass
    return text.split('\n')


allowed = set()
if os.path.isfile(allowed_file):
    allowed = {letters(line) for line in (read(allowed_file) or '').splitlines() if line.strip() and not line.startswith('#')}
    allowed.discard('')

grams = {}
for source in sources:
    for path in files(source):
        for piece in pieces(path):
            flat = letters(piece)
            for i in range(len(flat) - n + 1):
                gram = flat[i:i + n]
                if len(han.findall(gram)) >= n - 1:
                    grams.setdefault(gram, os.path.basename(path))

hits = 0
for path in files(target):
    text = read(path)
    if text is None:
        continue
    for number, line in enumerate(text.split('\n'), 1):
        flat = letters(line)
        copied = [flat[i:i + n] for i in range(len(flat) - n + 1) if flat[i:i + n] in grams]
        # A phrase on the allowed list covers the windows inside it.
        copied = [gram for gram in copied if not any(gram in phrase for phrase in allowed)]
        if copied:
            hits += 1
            print(f'text also found in the private files ({grams[copied[0]]}): '
                  f'{os.path.relpath(path, target)}:{number}: {copied[0]}' + (f' … {copied[-1]}' if len(copied) > 1 else ''))
sys.exit(1 if hits else 0)
PY
    else
        echo "note: no private text folders here (samples/, local/private-sources.txt): the copied-text check had nothing to compare with" >&2
    fi
fi

(( found )) && refuse

# ---------------------------------------------------------------- report

count="$(wc -l < "$LIST" | tr -d ' ')"
echo "exported $count files from $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')$( (( ALLOW_DIRTY )) && echo ' (working tree as it is)') to $TARGET:"
sed 's/^/  /' "$LIST"
echo
echo "checked: no audio, no .git, no secrets or personal paths or real e-mail addresses"
if (( PRIVATE_CHECKS )); then
    echo "checked: none of the $(grep -cvE '^(#|$)' "$PATTERNS") private words; no private correction as a pair; no run of $NGRAM Chinese characters shared with the private text folders"
else
    echo "NOT checked (--no-private-checks): private words, text copied from private files"
fi
echo

# ---------------------------------------------------------------- the one commit

if (( COMMIT )); then
    FINAL_MESSAGE="$(mktemp -t neoless-public)"
    trap 'rm -f "$LIST" "$REPORT" "$FINAL_MESSAGE"' EXIT
    mv "$MESSAGE_COPY" "$FINAL_MESSAGE"
    # UTC, written with its offset: the commit must not carry this machine's time zone.
    STAMP="$(date -u '+%Y-%m-%dT%H:%M:%S+0000')"
    if [[ -n "$ONTO" ]]; then
        # The next commit of the public repository: its tracked files go, the checked export comes in.
        before="$(git -C "$ONTO" rev-list --count HEAD)"
        git -C "$ONTO" ls-files -z | (cd "$ONTO" && xargs -0 rm -f)
        cp -Rp "$TARGET/." "$ONTO/"
        find "$TARGET" -mindepth 1 -delete
        cd "$ONTO"
    else
        before=0
        git init -q -b main
    fi
    git add -A
    if [[ -n "$ONTO" && -z "$(git status --porcelain)" ]]; then
        echo "nothing changed since the last public commit: $ONTO is as it was"
        exit 0
    fi
    TZ=UTC GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" GIT_AUTHOR_DATE="$STAMP" \
        GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" GIT_COMMITTER_DATE="$STAMP" \
        git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --cleanup=whitespace -F "$FINAL_MESSAGE"
    cat > .git/hooks/pre-push <<'HOOK'
#!/bin/bash
# Written by scripts/make-public.sh. This repository is a public export and is only ever pushed to a repository
# of its own. A remote that holds a commit this repository does not have is another project (the private
# repository, say): pushing there is refused, forced or not.
url="$2"
refuse() {
    echo "pre-push: $url already holds commits that are not from this repository ($1)." >&2
    echo "This tree is published as a repository of its own: create a new, empty one and push there." >&2
    exit 1
}
while read -r _ _ remote_ref remote_sha; do
    case "$remote_sha" in *[!0]*) git cat-file -e "$remote_sha^{commit}" 2>/dev/null || refuse "$remote_ref" ;; esac
done
refs="$(git ls-remote --heads --tags "$url")" || { echo "pre-push: could not list what $url holds; not pushing." >&2; exit 1; }
while read -r sha ref; do
    [[ -z "$sha" ]] || git cat-file -e "$sha" 2>/dev/null || refuse "$ref"
done <<< "$refs"
exit 0
HOOK
    chmod +x .git/hooks/pre-push
    [[ "$(git rev-list --count HEAD)" == "$(( before + 1 ))" && -z "$(git status --porcelain --ignored)" \
        && "$(git ls-files | wc -l | tr -d ' ')" == "$count" ]] \
        || fail "the commit in $PWD is not the $count exported files and nothing else; look before publishing"
    if [[ -n "$ONTO" ]]; then echo "committed in $ONTO (commit $(( before + 1 )) of the public repository):"
    else echo "committed in $TARGET (one commit, no parent):"; fi
    git log -1 --format='  %H%n  author:    %an <%ae>  %ad%n  committer: %cn <%ce>  %cd' --date=iso-strict
else
    echo "next, in $TARGET: one commit on a new repository (git init -b main), or run this script with --commit,"
    echo "which sees to the author, the dates and the message (see the top of this script)."
fi
echo "Publish it as a BRAND-NEW repository (later exports: --onto a clone of that repository). Never push a branch of the private repository, never add the private"
echo "repository as a remote here, and never switch the private repository to public."
