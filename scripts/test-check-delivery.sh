#!/usr/bin/env bash
# Regression tests for scripts/check-delivery.sh. Each case commits crafted
# templates and docs to a throwaway git repo, runs the checker, and compares the
# exit status and output with the expected result. Prints one line per case and
# exits 1 if any case behaves unexpectedly. Set AWK to test another awk
# (default: awk).
set -euo pipefail
unset GITHUB_ACTIONS

# Log which awk runs the checker. Try --version (gawk, BWK, newer mawk), then
# -W version (older mawk); stdin is closed so no awk can wait for input.
awk_bin=${AWK:-awk}
awk_version=$({ "$awk_bin" --version </dev/null 2>/dev/null || "$awk_bin" -W version </dev/null 2>/dev/null; } | head -n 1) || true
echo "awk: $awk_bin ${awk_version:-unknown}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-delivery-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/scripts"
cp "$here/check-delivery.sh" "$repo/scripts/check-delivery.sh"
git -C "$repo" init -q
git -C "$repo" add scripts/check-delivery.sh
git -C "$repo" -c user.name=test -c user.email=t@example.invalid commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)

failures=0

# begin_case: restore the base commit and an empty deliveries/ directory.
begin_case() {
  git -C "$repo" reset -q --hard "$base"
  rm -rf "$repo/deliveries"
  mkdir -p "$repo/deliveries"
}

# minimal_template: a template with two required sections.
minimal_template() {
  cat > "$repo/deliveries/TEMPLATE.md" <<'EOF'
# Title

## Why

## Evidence
EOF
}

# check NAME WANT_EXIT TEXT [TEXT2]: commit the working tree on top of base,
# run the checker, and require the exit status and each TEXT in the output.
check() {
  local name=$1 want=$2 text=$3 text2=${4:-} out code
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=t@example.invalid \
    commit -q --allow-empty -m "$name"
  out=$(cd "$repo" && bash scripts/check-delivery.sh "$base" HEAD 2>&1) && code=0 || code=$?
  if [ "$code" -eq "$want" ] \
    && grep -qF -- "$text" <<< "$out" \
    && { [ -z "$text2" ] || grep -qF -- "$text2" <<< "$out"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $code, want $want; expected text: $text${text2:+ / $text2})"
    while IFS= read -r line; do echo "     $line"; done <<< "$out"
    failures=$((failures + 1))
  fi
}

# 1-2. The real doc and template pass (CRLF too).
begin_case
cp "$root/deliveries/TEMPLATE.md" "$repo/deliveries/TEMPLATE.md"
cp "$root/deliveries/2026-11-05-delivery-docs.md" "$repo/deliveries/"
check "real doc passes" 0 "2026-11-05-delivery-docs.md: ok"

begin_case
cp "$root/deliveries/TEMPLATE.md" "$repo/deliveries/TEMPLATE.md"
sed 's/$/\r/' "$root/deliveries/2026-11-05-delivery-docs.md" > "$repo/deliveries/2026-11-05-delivery-docs.md"
check "real doc with CRLF passes" 0 "2026-11-05-delivery-docs.md: ok"

# 3. No doc.
begin_case
minimal_template
check "missing doc fails" 1 "no delivery doc added or updated"

# 4. Top-level ## Evidence missing.
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

Text only.
EOF
check "missing top-level ## Evidence fails" 1 "missing required section '## Evidence'"

# 5. Bad file name.
begin_case
minimal_template
cat > "$repo/deliveries/fence.md" <<'EOF'
# Title

## Why

## Evidence
EOF
check "bad file name fails" 1 "name must match"

# 6a. Qodo case: a ~~~ line inside a backtick example does not close the block,
# so ## Evidence inside the example must not count.
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

```markdown
~~~
## Evidence
```
EOF
check "backtick example with ~~~ hides ## Evidence (Qodo case) fails" 1 "missing required section '## Evidence'"

# 6b. A real top-level heading after a block that contains a mixed marker passes.
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

```markdown
~~~
## Example
```

## Evidence
EOF
check "real ## Evidence after a mixed-marker block passes" 0 "2026-11-05-fence.md: ok"

# 6c. A four-backtick fence containing ``` and ## X: ## X is not required.
begin_case
cat > "$repo/deliveries/TEMPLATE.md" <<'EOF'
# Title

## Why

````markdown
```
## X
```
````

## Evidence
EOF
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

## Evidence
EOF
check "four-backtick template example: ## X not required" 0 "2026-11-05-fence.md: ok"

# 6d. A ~~~ fence containing ## X: ## X is not required.
begin_case
cat > "$repo/deliveries/TEMPLATE.md" <<'EOF'
# Title

## Why

~~~
## X
~~~

## Evidence
EOF
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

## Evidence
EOF
check "tilde template example: ## X not required" 0 "2026-11-05-fence.md: ok"

# 6e. A fence indented three spaces is a fence (hides ## Evidence) ...
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

   ```
## Evidence
   ```
EOF
check "three-space indented fence hides ## Evidence fails" 1 "missing required section '## Evidence'"

# ... and a four-space indented line is not a fence.
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

    ```
## Evidence
EOF
check "four-space indented backticks are not a fence" 0 "2026-11-05-fence.md: ok"

# 6f. A ``` line whose info string contains a backtick is not a fence.
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

``` a`b
## Evidence
EOF
check "backtick info string makes the line not a fence" 0 "2026-11-05-fence.md: ok"

# 6h. A shorter ``` line does not close a four-backtick block.
begin_case
minimal_template
cat > "$repo/deliveries/2026-11-05-fence.md" <<'EOF'
# Title

## Why

````markdown
```
## Evidence
```
````
EOF
check "shorter fence does not close a longer block" 1 "missing required section '## Evidence'"

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed (awk: ${AWK:-awk})" >&2
  exit 1
fi
echo "all cases passed (awk: ${AWK:-awk})"
