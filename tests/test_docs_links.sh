#!/usr/bin/env bash
# Checks the links of every Markdown file in the repository: a relative link or image must point
# to an existing file or directory, and a `#fragment` must match a heading of the target file the
# way GitHub derives anchors from headings (github-slugger), in the same case. Reference
# definitions "[label]: target" are checked like links. Links to http://, https:// and mailto:
# are not checked, nor are links inside fenced code blocks and inline code. The checker is first
# run on fixtures that cover the anchor rules, then on the repository tree.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Cyrillic headings need a UTF-8 locale for [[:alnum:]] and ${var,,}; C.UTF-8 is part of glibc.
require_utf8_locale() {
    local upper="Ё"

    export LC_ALL=C.UTF-8
    if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ] || [ "${upper,,}" != "ё" ] || [[ "ж" != [[:alnum:]] ]]; then
        fail "the locale C.UTF-8 is required (locale charmap, \${var,,} and [[:alnum:]] must handle Cyrillic)"
    fi
}

# State of one tree: anchors per file, links found and errors.
declare -A ANCHORS=()   # absolute file -> "\nanchor\nanchor\n"
declare -A SLUG_SEEN=() # "file<TAB>slug" -> how many times that slug was extended with -N
declare -a LINKS=()     # "file<TAB>line<TAB>target"
declare -a ERRORS=()
DECODED=""    # result of url_decode
NORMALIZED="" # result of normalize_path
SLUG=""       # result of heading_slug
STRIPPED=""   # result of strip_code_spans

reset_state() {
    ANCHORS=()
    SLUG_SEEN=()
    LINKS=()
    ERRORS=()
}

# Collapses `.` and `..` in an absolute path into NORMALIZED without touching the file system.
normalize_path() {
    local -a parts=() out=()
    local part

    IFS='/' read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|.) ;;
            ..) [ "${#out[@]}" -eq 0 ] || unset 'out[-1]' ;;
            *) out+=("$part") ;;
        esac
    done
    if [ "${#out[@]}" -eq 0 ]; then
        NORMALIZED="/"
    else
        printf -v NORMALIZED '/%s' "${out[@]}"
    fi
}

# Decodes %XX escapes into DECODED. The text is consumed from the left, so =~ only ever sees
# the untouched (valid UTF-8) remainder, never a half-decoded sequence.
url_decode() {
    local text="$1" prefix byte

    DECODED=""
    while [[ $text == *%* ]]; do
        prefix="${text%%%*}"
        text="${text#*%}"
        if [[ ${text:0:2} =~ ^[0-9A-Fa-f]{2}$ ]]; then
            printf -v byte '%b' "\\x${text:0:2}"
            DECODED+="${prefix}${byte}"
            text="${text:2}"
        else
            DECODED+="${prefix}%"
        fi
    done
    DECODED+="$text"
}

# The anchor GitHub gives a heading: the visible text (inline code and link text kept, emphasis
# markers and HTML tags dropped) in lower case, everything except letters, digits, `_`, `-` and
# spaces removed, each space turned into `-`. The result is SLUG.
heading_slug() {
    local text="$1" word
    local -a words=()
    local re_link='^(.*)\[([^]]*)\]\([^)]*\)(.*)$'
    local re_tag='^(.*)<[^<>]*>(.*)$'

    text="${text//\`/}"
    while [[ $text =~ $re_link ]]; do
        text="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    done
    while [[ $text =~ $re_tag ]]; do
        text="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    done
    text="${text//\*/}"
    # Underscores open or close emphasis only at a word boundary; snake_case keeps its own.
    read -ra words <<< "$text"
    text=""
    for word in "${words[@]}"; do
        while [[ $word == _* ]]; do word="${word#_}"; done
        while [[ $word == *_ ]]; do word="${word%_}"; done
        text+="${text:+ }$word"
    done
    # Trim after the markup is gone, like the heading text GitHub slugs.
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    text="${text,,}"
    text="${text//[^[:alnum:]_ -]/}"
    SLUG="${text// /-}"
}

add_anchor() {
    local file="$1" anchor="$2"

    ANCHORS["$file"]+="${anchor}"$'\n'
}

# Numbered like github-slugger: a taken slug gets -1, -2, ... until the result is free, so the
# headings "Повтор-1", "Повтор", "Повтор" give "повтор-1", "повтор", "повтор-2".
add_heading() {
    local file="$1" text="$2" slug original

    heading_slug "$text"
    slug="$SLUG"
    original="$slug"
    while [ -n "${SLUG_SEEN["$file"$'\t'"$slug"]+set}" ]; do
        SLUG_SEEN["$file"$'\t'"$original"]=$((SLUG_SEEN["$file"$'\t'"$original"] + 1))
        slug="$original-${SLUG_SEEN["$file"$'\t'"$original"]}"
    done
    SLUG_SEEN["$file"$'\t'"$slug"]=0
    add_anchor "$file" "$slug"
}

# Drops inline code from a line into STRIPPED. The line is split on backticks (a run of k
# backticks is k-1 empty fields); a run opens a span that the next run of the same length closes,
# a run without a closing one is literal text. No regular expression: =~ is slow on long lines.
strip_code_spans() {
    local -a fields=() runs=() texts=()
    local i count kept run j k

    IFS='`' read -ra fields <<< "$1"$'\x01'
    count="${#fields[@]}"
    kept="${fields[0]}"
    i=1
    while [ "$i" -lt "$count" ]; do
        run=1
        while [ -z "${fields[i]}" ]; do
            run=$((run + 1))
            i=$((i + 1))
        done
        runs+=("$run")
        texts+=("${fields[i]}")
        i=$((i + 1))
    done
    count="${#runs[@]}"
    j=0
    while [ "$j" -lt "$count" ]; do
        k=$((j + 1))
        while [ "$k" -lt "$count" ] && [ "${runs[k]}" -ne "${runs[j]}" ]; do
            k=$((k + 1))
        done
        if [ "$k" -lt "$count" ]; then
            kept+="${texts[k]}"
            j=$((k + 1))
        else
            printf -v run '%*s' "${runs[j]}" ''
            kept+="${run// /\`}${texts[j]}"
            j=$((j + 1))
        fi
    done
    STRIPPED="${kept%$'\x01'}"
}

# Records the link targets of one line that is outside fenced code; inline code is dropped first.
collect_links() {
    local file="$1" number="$2" line="$3" rest target item
    local re_md='\]\((<[^>]*>|[^)]*)\)(.*)$'
    local re_html='(src|srcset|href)="([^"]*)"(.*)$'
    local re_id='<a[[:space:]][^>]*(id|name)="([^"]*)"'
    local re_definition='^ {0,3}\[[^]]+\]:[[:space:]]+(<[^>]*>|[^[:space:]]+)'

    # Only a line with one of these can carry a link or an anchor.
    [[ $line == *']('* || $line == *']:'* || $line == *'="'* || $line == *'<a'* ]] || return 0
    # A reference definition "[label]: target" is checked like a link.
    if [[ $line == *']:'* && $line =~ $re_definition ]]; then
        target="${BASH_REMATCH[1]}"
        target="${target#<}"
        target="${target%>}"
        LINKS+=("$file"$'\t'"$number"$'\t'"$target")
        return 0
    fi
    if [[ $line == *'`'* ]]; then
        strip_code_spans "$line"
        line="$STRIPPED"
    fi

    # The substring tests keep the regular expressions off the lines that cannot match.
    rest="$line"
    [[ $rest == *']('* ]] || rest=""
    while [[ $rest =~ $re_md ]]; do
        target="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        if [[ $target == \<* ]]; then
            target="${target#<}"
            target="${target%%>*}"
        else
            # A title in quotes follows the target after a space.
            target="${target%%[[:space:]]*}"
        fi
        LINKS+=("$file"$'\t'"$number"$'\t'"$target")
    done

    rest="$line"
    [[ $rest == *'="'* ]] || rest=""
    while [[ $rest =~ $re_html ]]; do
        target="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        # srcset lists "url [descriptor]" candidates separated by commas.
        while IFS= read -r -d ',' item || [ -n "$item" ]; do
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%%[[:space:]]*}"
            [ -z "$item" ] || LINKS+=("$file"$'\t'"$number"$'\t'"$item")
        done <<< "$target,"
    done

    rest="$line"
    [[ $rest == *'<a'* ]] || rest=""
    while [[ $rest =~ $re_id ]]; do
        add_anchor "$file" "${BASH_REMATCH[2]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
}

# Reads one Markdown file: headings and explicit anchors into ANCHORS, link targets into LINKS.
scan_file() {
    local file="$1" line number=0 fence_char="" fence_len=0 text
    local re_fence='^[[:space:]]*(`{3,}|~{3,})(.*)$'
    local re_heading='^ {0,3}#{1,6}([[:space:]]+(.*))?$'
    local re_closing='^(.*)[[:space:]]#+[[:space:]]*$'
    local re_close

    [ -z "${ANCHORS["$file"]+set}" ] || return 0
    ANCHORS["$file"]=$'\n'
    # shellcheck disable=SC2094  # $file is only read; the functions write to arrays
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        if [ -n "$fence_char" ]; then
            re_close="^[[:space:]]*${fence_char}{${fence_len},}[[:space:]]*\$"
            [[ $line =~ $re_close ]] && fence_char=""
            continue
        fi
        # The substring and prefix tests keep the regular expressions off most lines.
        if [[ ($line == *'```'* || $line == *'~~~'*) && $line =~ $re_fence ]]; then
            # An info string with a backtick means inline code, not a backtick fence.
            if [ "${BASH_REMATCH[1]:0:1}" != '`' ] || [[ ${BASH_REMATCH[2]} != *'`'* ]]; then
                fence_char="${BASH_REMATCH[1]:0:1}"
                fence_len="${#BASH_REMATCH[1]}"
                continue
            fi
        fi
        if [[ ($line == '#'* || $line == ' #'* || $line == '  #'* || $line == '   #'*) && $line =~ $re_heading ]]; then
            text="${BASH_REMATCH[2]:-}"
            [[ $text =~ $re_closing ]] && text="${BASH_REMATCH[1]}"
            [[ $text =~ ^#+[[:space:]]*$ ]] && text=""
            add_heading "$file" "$text"
        fi
        collect_links "$file" "$number" "$line"
    done < "$file"
}

# Resolves every recorded link; ERRORS gets "relative file:line: message".
check_links() {
    local root="$1" entry file number target path fragment resolved where

    for entry in "${LINKS[@]}"; do
        IFS=$'\t' read -r file number target <<< "$entry"
        where="${file#"$root"/}:$number"
        [ -n "$target" ] || continue
        case "${target,,}" in
            http://*|https://*|mailto:*) continue ;;
        esac

        path="${target%%#*}"
        fragment=""
        [[ $target != *#* ]] || fragment="${target#*#}"
        url_decode "$path"
        path="$DECODED"
        url_decode "$fragment"
        fragment="$DECODED"

        if [ -z "$path" ]; then
            resolved="$file"
        elif [[ $path == /* ]]; then
            normalize_path "$root$path"
            resolved="$NORMALIZED"
        else
            normalize_path "${file%/*}/$path"
            resolved="$NORMALIZED"
        fi
        if [ ! -e "$resolved" ]; then
            ERRORS+=("$where: битая ссылка $target")
            continue
        fi
        [ -n "$fragment" ] || continue
        # Only Markdown targets have anchors to check.
        [[ $resolved == *.md ]] && [ -f "$resolved" ] || continue
        scan_file "$resolved"
        # GitHub writes anchors in lower case; a link is compared as written.
        if [[ ${ANCHORS["$resolved"]} != *$'\n'"$fragment"$'\n'* ]]; then
            ERRORS+=("$where: битый якорь $target")
        fi
    done
}

# The files of the tree under root, relative to it, one per line. In a git work tree these are
# the files git tracks or does not ignore (a local .idea/ or an ignored draft must not fail the
# test; a deleted but still tracked file is skipped); without .git (a `git archive`) every file.
list_repository_files() {
    local root="$1" file

    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            if [ -f "$root/$file" ]; then
                printf '%s\n' "$file"
            fi
        done < <(git -C "$root" ls-files -z --cached --others --exclude-standard)
    else
        (cd "$root" && find . -path './.git' -prune -o -type f -printf '%P\n')
    fi | sort
}

# Scans every Markdown file under root (except .git) and prints the errors, one per line.
check_tree() {
    local root="$1" file

    reset_state
    while IFS= read -r file; do
        [[ $file == *.md ]] || continue
        scan_file "$root/$file"
    done < <(list_repository_files "$root")
    check_links "$root"
    printf '%s\n' "${ERRORS[@]+"${ERRORS[@]}"}"
}

test_checker_on_fixtures() {
    local tmp_dir expected actual

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir:-}"' RETURN

    mkdir -p "$tmp_dir/docs/assets"
    : > "$tmp_dir/docs/assets/pic.svg"
    : > "$tmp_dir/docs/sp ace.md"
    cat > "$tmp_dir/docs/guide.md" <<'EOF'
# Guide

## Раздел

<a id="custom-anchor"></a>
Back to the [overview](../README.md#-быстрый-старт).
EOF
    cat > "$tmp_dir/README.md" <<'EOF'
# Title

## 🚀 Быстрый старт
## Файлы, которые пишет скрипт
## Debian 11/12 → 13
## Повтор-1
## Повтор
## Повтор
## Функция `common_apt_get` и [ссылка](docs/guide.md) ##
## **Жирный** и _курсив_ в snake_case
    # not a heading: indented code
Anchors: [a](#-быстрый-старт) [b](#файлы-которые-пишет-скрипт) [c](#debian-1112--13)
[d](#повтор) [e](#повтор-1) [e2](#повтор-2) [f](#функция-common_apt_get-и-ссылка) [g](#жирный-и-курсив-в-snake_case)
Files: [h](docs/guide.md#раздел) [i](docs/) [j](<docs/sp ace.md>) [k](docs/sp%20ace.md "a title")
[l](/docs/guide.md#%D1%80%D0%B0%D0%B7%D0%B4%D0%B5%D0%BB) [m](docs/guide.md#custom-anchor) ![pic](docs/assets/pic.svg)
<img src="docs/assets/pic.svg" srcset="docs/assets/pic.svg 1x, docs/assets/pic.svg 2x"> <a href="docs/guide.md#раздел">x</a>
[ref1]: docs/guide.md#раздел
[ref2]: <docs/sp ace.md> "a title"
[ref3]: https://example.com/x.md
Skipped: [n](https://example.com/x.md) [o](http://example.com) [p](mailto:me@example.com) `[q](nowhere.md)`
``[r](nowhere.md) ` still code``

```bash
cat [s](nowhere.md) # inside a fence
```

~~~
[t](nowhere.md) [u](#nowhere)
~~~

Broken: [v](docs/missing.md)
Broken: [w](#nowhere)
Broken: [x](docs/guide.md#nowhere)
Broken: <img src="docs/assets/none.svg">
Broken: [y](#Title) [z](docs/guide.md#Раздел)
Broken: [aa](#повтор-3)

[broken-ref]: docs/none.md
EOF

    expected="$(printf '%s\n' \
        "README.md:31: битая ссылка docs/missing.md" \
        "README.md:32: битый якорь #nowhere" \
        "README.md:33: битый якорь docs/guide.md#nowhere" \
        "README.md:34: битая ссылка docs/assets/none.svg" \
        "README.md:35: битый якорь #Title" \
        "README.md:35: битый якорь docs/guide.md#Раздел" \
        "README.md:36: битый якорь #повтор-3" \
        "README.md:38: битая ссылка docs/none.md")"
    actual="$(check_tree "$tmp_dir")"
    [ "$actual" = "$expected" ] || fail "the checker reports on the fixtures:"$'\n'"$actual"$'\n'"expected:"$'\n'"$expected"
}

test_repository_links() {
    local errors

    errors="$(check_tree "$ROOT_DIR")"
    [ -z "$errors" ] || fail "broken links in the documentation:"$'\n'"$errors"
}

main() {
    require_utf8_locale
    test_checker_on_fixtures
    test_repository_links
    printf 'tests/test_docs_links.sh: OK\n'
}

main "$@"
