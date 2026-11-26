#!/usr/bin/env bash
set -euo pipefail

# Exercise verification without an RPC, explorer account, or private key.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
bash -n script/deploy/verify-atlas.sh
bash script/deploy/verify-atlas.sh --help >/dev/null

TEST_DIR="$(mktemp -d)"
mkdir "$TEST_DIR/bin" "$TEST_DIR/log"
cleanup() {
    rm -f "$TEST_DIR/bin/cast" "$TEST_DIR/bin/forge" "$TEST_DIR/test.env" "$TEST_DIR/output" "$TEST_DIR/log/"*.args "$TEST_DIR/log/calls"
    rmdir "$TEST_DIR/bin" "$TEST_DIR/log" "$TEST_DIR"
}
trap cleanup EXIT
address() { printf '0x%040x' "$1"; }
export MOCK_USDC="$(address 1)" MOCK_PERP_LP="$(address 2)" MOCK_PERP="$(address 3)"
export MOCK_OPTION_LP="$(address 4)" MOCK_OPTION="$(address 5)"
export MOCK_PREDICTION_LP="$(address 6)" MOCK_PREDICTION="$(address 7)"
export MOCK_SIGNER="$(address 8)" MOCK_LOG_DIR="$TEST_DIR/log"

cat > "$TEST_DIR/bin/cast" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    chain-id) printf '%s\n' "${MOCK_CHAIN_ID:-8453}" ;;
    code) printf '%s\n' "${MOCK_CODE:-0x6000}" ;;
    call)
        case "$3" in
            'usdc()(address)') echo "$MOCK_USDC" ;;
            'ppUSDC()(address)') echo "${MOCK_PERP_LINK:-$MOCK_PERP_LP}" ;;
            'opUSDC()(address)') echo "$MOCK_OPTION_LP" ;;
            'shareToken()(address)') echo "$MOCK_PREDICTION_LP" ;;
            'maxPriceAge()(uint256)') echo '12000 [1.2e4]' ;;
            'feeBps()(uint256)') echo 125 ;;
            *) exit 1 ;;
        esac
        ;;
    abi-encode)
        shift
        printf 'encoded'
        printf ':%s' "$@"
        printf '\n'
        ;;
    *) exit 1 ;;
esac
MOCK
cat > "$TEST_DIR/bin/forge" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
CONTRACT="${!#}"
printf '%s\n' "$*" > "$MOCK_LOG_DIR/${CONTRACT##*:}.args"
printf '%s\n' "$CONTRACT" >> "$MOCK_LOG_DIR/calls"
[[ "$FOUNDRY_PROFILE" == default ]] || exit 1
if [[ "$*" == *'--verifier sourcify'* ]]; then
    [[ -z "$ETHERSCAN_API_KEY" && -z "$VERIFIER_API_KEY" ]] || exit 1
fi
if [[ "${MOCK_ECHO_ARGS:-0}" == 1 ]]; then printf '%s\n' "$*"; fi
if [[ "$CONTRACT" == "${MOCK_FAIL_CONTRACT:-}" ]]; then exit 1; fi
MOCK
chmod +x "$TEST_DIR/bin/cast" "$TEST_DIR/bin/forge"
export PATH="$TEST_DIR/bin:$PATH"

write_env() {
    # Deliberately omit PRIVATE_KEY; unrelated Pyth addresses are unnecessary.
    printf '%s\r\n' \
        'RPC_URL=http://localhost:8545' "CHAIN_ID=${1:-8453}" \
        "USDC_ADDRESS=$MOCK_USDC" "ATLAS_PPUSDC_ADDRESS=$MOCK_PERP_LP" \
        "PERPDEX_ATLAS_ADDRESS=$MOCK_PERP" "ATLAS_OPUSDC_ADDRESS=$MOCK_OPTION_LP" \
        "OPTION_AMM_ATLAS_ADDRESS=$MOCK_OPTION" "ATLAS_PMUSDC_ADDRESS=$MOCK_PREDICTION_LP" \
        "PREDICTION_MARKET_AMM_ATLAS_ADDRESS=$MOCK_PREDICTION" "ATLAS_SIGNER=$MOCK_SIGNER" \
        'ATLAS_MAX_PRICE_AGE=5' 'PREDICTION_FEE_BPS=300' \
        "ETHERSCAN_API_KEY='${2-test-key}'" "BLOCKSCOUT_API_KEY='${3-}'" > "$TEST_DIR/test.env"
}
run_script() {
    : > "$MOCK_LOG_DIR/calls"
    bash script/deploy/verify-atlas.sh "$TEST_DIR/test.env" > "$TEST_DIR/output" 2>&1
}
assert_contains() {
    if [[ "$(<"$1")" != *"$2"* ]]; then
        echo "Missing expected output: $2" >&2
        exit 1
    fi
}
assert_call_count() {
    local count=0 line
    while IFS= read -r line; do count=$((count + 1)); done < "$MOCK_LOG_DIR/calls"
    [[ "$count" == "$1" ]] || { echo "Expected $1 verification calls, got $count" >&2; exit 1; }
}

write_env
run_script
assert_call_count 6
assert_contains "$TEST_DIR/output" '6 succeeded, 0 failed'
assert_contains "$MOCK_LOG_DIR/PerpDexAtlas.args" "encoded:constructor(address,address,address,uint256):$MOCK_USDC:$MOCK_PERP_LP:$MOCK_SIGNER:12000"
assert_contains "$MOCK_LOG_DIR/OptionAMMAtlas.args" "encoded:constructor(address,address,address):$MOCK_USDC:$MOCK_SIGNER:$MOCK_OPTION_LP"
assert_contains "$MOCK_LOG_DIR/PredictionMarketAMMAtlas.args" "encoded:constructor(address,address,uint256):$MOCK_USDC:$MOCK_SIGNER:125"
assert_contains "$MOCK_LOG_DIR/pmUSDC.args" "encoded:constructor(address):$MOCK_PREDICTION"
assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--compiler-version 0.8.20 --num-of-optimizations 1 --via-ir'
assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--verifier-url https://api.etherscan.io/v2/api?chainid=8453'
assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--watch'
[[ "$(<"$MOCK_LOG_DIR/opUSDC.args")" != *'--constructor-args'* ]]

if MOCK_CHAIN_ID=1 run_script; then exit 1; fi
assert_call_count 0
if MOCK_CODE=0x run_script; then exit 1; fi
assert_call_count 0
if MOCK_PERP_LINK="$MOCK_OPTION_LP" run_script; then exit 1; fi
assert_call_count 0
if MOCK_FAIL_CONTRACT=src/OptionAMMAtlas.sol:OptionAMMAtlas run_script; then exit 1; fi
assert_call_count 6
assert_contains "$TEST_DIR/output" '5 succeeded, 1 failed'

write_env 8453 ''
if run_script; then exit 1; fi
assert_call_count 0
for CHAIN in 143 10143 4663 46630; do
    write_env "$CHAIN" unrelated-etherscan-key
    MOCK_CHAIN_ID="$CHAIN" run_script
    assert_call_count 6
    assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--verifier sourcify'
    [[ "$(<"$MOCK_LOG_DIR/ppUSDC.args")" != *'--etherscan-api-key'* ]]
    if [[ "$CHAIN" == 4663 || "$CHAIN" == 46630 ]]; then
        assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--watch'
    fi
done

write_env 4663 '' 'fake key+/&'
MOCK_CHAIN_ID=4663 MOCK_ECHO_ARGS=1 run_script
assert_call_count 6
assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--verifier blockscout'
assert_contains "$MOCK_LOG_DIR/ppUSDC.args" 'apikey=fake%20key%2B%2F%26'
assert_contains "$MOCK_LOG_DIR/ppUSDC.args" '--skip-is-verified-check'
[[ "$(<"$TEST_DIR/output")" != *'fake key+/&'* ]]
[[ "$(<"$TEST_DIR/output")" != *'fake%20key%2B%2F%26'* ]]
assert_contains "$TEST_DIR/output" '[redacted]'

echo 'Passed Atlas verification checks: all six contracts, constructor arguments, immutable settings, providers, preflight failures, failure summary, CRLF, API key redaction, and no private key.'
