#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
RUNNER=script/deploy/deploy-prediction-atlas.sh
bash -n "$RUNNER"
bash "$RUNNER" --help >/dev/null

TEST_DIR="$(mktemp -d)"
mkdir "$TEST_DIR/bin"
cleanup() {
    rm -f "$TEST_DIR/bin/cast" "$TEST_DIR/bin/forge" "$TEST_DIR/test.env" \
        "$TEST_DIR/output" "$TEST_DIR/args" "$TEST_DIR/config"
    rmdir "$TEST_DIR/bin" "$TEST_DIR"
}
trap cleanup EXIT
cat > "$TEST_DIR/bin/cast" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == chain-id ]] || exit 1
printf '%s\n' "${MOCK_CHAIN_ID:-8453}"
MOCK
cat > "$TEST_DIR/bin/forge" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_LOG_DIR/args"
printf '%s\n' "$ATLAS_SIGNER" "$PREDICTION_FEE_BPS" "$FOUNDRY_PROFILE" > "$MOCK_LOG_DIR/config"
exit "${MOCK_FORGE_EXIT:-0}"
MOCK
chmod +x "$TEST_DIR/bin/cast" "$TEST_DIR/bin/forge"
export PATH="$TEST_DIR/bin:$PATH" MOCK_LOG_DIR="$TEST_DIR"
write_env() {
    printf '%s\r\n' 'PRIVATE_KEY=1' 'RPC_URL=http://localhost:8545' "CHAIN_ID=${1:-8453}" \
        'USDC_ADDRESS=0x0000000000000000000000000000000000000001' \
        "ATLAS_SIGNER=${2-}" "PREDICTION_FEE_BPS=${3-}" 'FOUNDRY_PROFILE=eip7702' > "$TEST_DIR/test.env"
}
run_script() {
    : > "$TEST_DIR/args"
    bash "$RUNNER" "$TEST_DIR/test.env" "$@" > "$TEST_DIR/output" 2>&1
}
has_arg() { [[ $'\n'"$(<"$TEST_DIR/args")"$'\n' == *$'\n'"$1"$'\n'* ]]; }
write_env
run_script
has_arg script/DeployPredictionMarketAMMAtlas.s.sol:DeployPredictionMarketAMMAtlas
! has_arg script/DeployAtlas.s.sol:DeployAtlas
! has_arg --broadcast
! has_arg --private-key
[[ "$(<"$TEST_DIR/config")" == $'0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600\n300\ndefault' ]]
run_script --dry-run
! has_arg --broadcast
run_script --broadcast
has_arg --broadcast
has_arg --slow
[[ "$(<"$TEST_DIR/output")" == *'Deployment confirmed.'* ]]
[[ "$(<"$TEST_DIR/output")" == *'prediction --broadcast'* ]]
run_script --broadcast --resume
has_arg --resume
has_arg --private-key
has_arg 1
run_script --broadcast --start-fresh
has_arg --start-fresh

for RECOVERY in --resume --start-fresh; do
    if run_script "$RECOVERY"; then exit 1; fi
    [[ ! -s "$TEST_DIR/args" ]]
done
if run_script --broadcast --dry-run; then exit 1; fi
if run_script --broadcast --resume --start-fresh; then exit 1; fi
if run_script --unknown; then exit 1; fi
if MOCK_CHAIN_ID=1 run_script --broadcast; then exit 1; fi
[[ ! -s "$TEST_DIR/args" ]]
if MOCK_FORGE_EXIT=1 run_script --broadcast; then exit 1; fi
[[ "$(<"$TEST_DIR/output")" == *'Atlas prediction deployment failed.'* ]]
[[ "$(<"$TEST_DIR/output")" != *'Deployment confirmed.'* ]]

write_env 56 0x0000000000000000000000000000000000000002 125
MOCK_CHAIN_ID=56 run_script --broadcast
has_arg --legacy
[[ "$(<"$TEST_DIR/config")" == $'0x0000000000000000000000000000000000000002\n125\ndefault' ]]
write_env
printf '%s\r\n' 'PRIVATE_KEY=' >> "$TEST_DIR/test.env"
if run_script --broadcast; then exit 1; fi
[[ ! -s "$TEST_DIR/args" ]]
[[ "$(<"$TEST_DIR/output")" == *'PRIVATE_KEY is not set'* ]]
if bash "$RUNNER" "$TEST_DIR/missing.env" > "$TEST_DIR/output" 2>&1; then exit 1; fi

echo 'Passed Atlas prediction deployment runner checks: isolated target, defaults, CRLF, simulation, broadcast, recovery, chain validation, chain 56, configuration, and failures.'
