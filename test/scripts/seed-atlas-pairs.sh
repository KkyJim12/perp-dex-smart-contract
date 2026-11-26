#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
bash -n script/deploy/seed-atlas-pairs.sh
bash script/deploy/seed-atlas-pairs.sh --help >/dev/null

TEST_DIR="$(mktemp -d)"
mkdir "$TEST_DIR/bin"
cleanup() {
    rm -f "$TEST_DIR/bin/cast" "$TEST_DIR/bin/forge" "$TEST_DIR/test.env" "$TEST_DIR/output" "$TEST_DIR/args" "$TEST_DIR/target"
    rmdir "$TEST_DIR/bin" "$TEST_DIR"
}
trap cleanup EXIT
cat > "$TEST_DIR/bin/cast" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_CHAIN_ID:-8453}"
MOCK
cat > "$TEST_DIR/bin/forge" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_LOG_DIR/args"
printf '%s\n' "$ATLAS_SEED_TARGET" > "$MOCK_LOG_DIR/target"
exit "${MOCK_FORGE_EXIT:-0}"
MOCK
chmod +x "$TEST_DIR/bin/cast" "$TEST_DIR/bin/forge"
export PATH="$TEST_DIR/bin:$PATH" MOCK_LOG_DIR="$TEST_DIR"
printf '%s\r\n' 'PRIVATE_KEY=1' 'RPC_URL=http://localhost:8545' 'CHAIN_ID=8453' \
    'ATLAS_SEED_TARGET=ignored-environment-value' > "$TEST_DIR/test.env"
run_script() {
    : > "$TEST_DIR/args"
    bash script/deploy/seed-atlas-pairs.sh "$TEST_DIR/test.env" "$@" > "$TEST_DIR/output" 2>&1
}
has_arg() { [[ $'\n'"$(<"$TEST_DIR/args")"$'\n' == *$'\n'"$1"$'\n'* ]]; }
run_script
[[ "$(<"$TEST_DIR/target")" == all ]]
has_arg script/ConfigureAtlasPairs.s.sol:ConfigureAtlasPairs
! has_arg --broadcast
for TARGET in all perp option prediction; do
    run_script "$TARGET" --broadcast
    [[ "$(<"$TEST_DIR/target")" == "$TARGET" ]]
    has_arg --broadcast
done
run_script option --dry-run
! has_arg --broadcast
run_script prediction --broadcast --resume
has_arg --resume
has_arg --private-key
if run_script --resume; then exit 1; fi
if run_script --broadcast --dry-run; then exit 1; fi
if run_script invalid-target; then exit 1; fi
if run_script --unknown; then exit 1; fi
if MOCK_CHAIN_ID=1 run_script --broadcast; then exit 1; fi
[[ ! -s "$TEST_DIR/args" ]]
if MOCK_FORGE_EXIT=1 run_script --broadcast; then exit 1; fi
[[ "$(<"$TEST_DIR/output")" == *'Atlas pair seeding failed'* ]]

printf '%s\r\n' 'PRIVATE_KEY=1' 'RPC_URL=http://localhost:8545' 'CHAIN_ID=56' > "$TEST_DIR/test.env"
MOCK_CHAIN_ID=56 run_script perp --broadcast
has_arg --legacy

# A target alone must be parsed as a target, rather than an environment filename.
bash script/deploy/seed-atlas-pairs.sh option --help >/dev/null
echo 'Passed Atlas seed runner checks: targets, CRLF, simulation, broadcast, resume, chain mismatch, chain 56, conflicting flags, and forge failure.'
