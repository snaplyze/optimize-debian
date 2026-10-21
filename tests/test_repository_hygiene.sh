#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_no_crlf_in_shell_or_docs() {
    local file

    while IFS= read -r file; do
        if LC_ALL=C grep -q $'\r' "$ROOT_DIR/$file"; then
            fail "CRLF line endings are not allowed in $file"
        fi
    done < <(
        cd "$ROOT_DIR"
        find . \
            -path './.git' -prune -o \
            -type f \( -name '*.sh' -o -name '*.md' -o -name '.gitignore' -o -name '.gitattributes' \) \
            -printf '%P\n'
    )
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

# Every file grep -I takes for text: no trailing whitespace, no blank line at the end of the file
# (what `git diff --check` reports as blank-at-eof).
test_no_trailing_whitespace() {
    local file lines
    local -a offenders=()

    while IFS= read -r file; do
        LC_ALL=C grep -Iq '' "$ROOT_DIR/$file" || continue
        # grep returns 1 for a clean file, which pipefail would turn into a failure.
        lines="$({ LC_ALL=C grep -nE '[[:space:]]+$' "$ROOT_DIR/$file" || true; } | cut -d: -f1 | paste -sd ',' -)"
        [ -z "$lines" ] || offenders+=("$file: trailing whitespace on lines $lines")
        if [ -z "$(tail -c 2 "$ROOT_DIR/$file" | tr -d '\n')" ]; then
            offenders+=("$file: blank line at the end of the file")
        fi
    done < <(list_repository_files "$ROOT_DIR")
    [ "${#offenders[@]}" -eq 0 ] || fail "whitespace errors:"$'\n'"$(printf '%s\n' "${offenders[@]}")"
}

test_shell_scripts_parse() {
    local file

    cd "$ROOT_DIR"
    # `bash -n a.sh b.sh` checks only a.sh (the rest become its arguments), so check each file.
    for file in *.sh lib/*.sh tests/*.sh; do
        [ -f "$file" ] || fail "no shell scripts matched: $file"
        bash -n "$file" || fail "syntax error in $file"
    done
}

test_optimizer_scripts_source_without_lib_directory() {
    local script
    local tmp_dir

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir:-}"' RETURN

    for script in optimize_wsl2.sh optimize_vps.sh optimize_mini_pc.sh optimize_amnezia_host.sh; do
        cp "$ROOT_DIR/$script" "$tmp_dir/$script"
        OPTIMIZE_SOURCE_ONLY=1 bash "$tmp_dir/$script"
    done
}

test_optimizer_scripts_source_from_process_substitution() {
    local script

    for script in optimize_wsl2.sh optimize_vps.sh optimize_mini_pc.sh optimize_amnezia_host.sh; do
        SCRIPT="$ROOT_DIR/$script" OPTIMIZE_SOURCE_ONLY=1 bash -c 'source <(cat "$SCRIPT")'
    done
}

test_embedded_tui_auto_backend_matches_gum_style() {
    local script

    for script in optimize_wsl2.sh optimize_vps.sh optimize_mini_pc.sh; do
        SCRIPT="$ROOT_DIR/$script" OPTIMIZE_SOURCE_ONLY=1 bash -c '
            set -euo pipefail
            source "$SCRIPT"
            tmp_bin="$(mktemp -d)"
            trap "rm -rf \"$tmp_bin\"" EXIT

            printf "%s\n" "#!/usr/bin/env bash" "exit 0" > "$tmp_bin/whiptail"
            chmod +x "$tmp_bin/whiptail"
            [ "$(GUM=/nonexistent/gum TUI_AUTO_INSTALL_GUM=false PATH="$tmp_bin" tui_detect_backend)" = "plain" ]

            printf "%s\n" "#!/usr/bin/env bash" "exit 0" > "$tmp_bin/gum"
            chmod +x "$tmp_bin/gum"
            [ "$(GUM=/nonexistent/gum TUI_AUTO_INSTALL_GUM=false PATH="$tmp_bin" tui_detect_backend)" = "gum" ]
        '
    done
}

test_optimizer_visual_shell_uses_clean_style() {
    local script

    for script in optimize_wsl2.sh optimize_vps.sh optimize_mini_pc.sh optimize_amnezia_host.sh; do
        if grep -Eq '(echo|printf).*(╔|╚|║|┌|└|│|═{3,}|─{6,})' "$ROOT_DIR/$script"; then
            fail "$script should not render old box-drawing panels"
        fi

        grep -q '^ui_clean_heading()' "$ROOT_DIR/$script" || \
            fail "$script should normalize visual headings"
        grep -q '^ui_message()' "$ROOT_DIR/$script" || \
            fail "$script should use aligned status labels"
    done

    grep -q '^print_header()' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail "optimize_wsl2.sh should define a TUI-aware header"
    grep -q 'WSL2 Optimization for Debian 12/13' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail "optimize_wsl2.sh header title is missing"
    grep -q '^ui_success_title()' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail "optimize_wsl2.sh should use styled success titles"
}

main() {
    test_no_crlf_in_shell_or_docs
    test_no_trailing_whitespace
    test_shell_scripts_parse
    test_optimizer_scripts_source_without_lib_directory
    test_optimizer_scripts_source_from_process_substitution
    test_embedded_tui_auto_backend_matches_gum_style
    test_optimizer_visual_shell_uses_clean_style
    printf 'tests/test_repository_hygiene.sh: OK\n'
}

main "$@"
