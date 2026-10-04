// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @notice EIP-7702 delegation implementation for atomic approvals and market calls.
/// @dev CALL preserves the delegated EOA as msg.sender in PerpDex, PredictionMarketAMM
/// and OptionsAMM. No initializer, administrator, or shared custody is required.
contract TradingAccount7702 {
    struct Call {
        address target;
        uint256 value;
        uint256 gasLimit;
        bytes data;
    }

    /// @custom:storage-location erc7201:perpdex.storage.TradingAccount7702
    struct AccountStorage {
        uint256 nonce;
        bool executing;
    }

    address public immutable IMPLEMENTATION = address(this);

    bytes32 public constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,uint256 gasLimit,bytes data)");
    bytes32 public constant BATCH_TYPEHASH = keccak256(
        "Batch(Call[] calls,uint256 nonce,uint256 deadline,address relayer,uint256 funding)Call(address target,uint256 value,uint256 gasLimit,bytes data)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");

    error NotDelegated();
    error Unauthorized();
    error ReentrantExecution();
    error EmptyBatch();
    error InvalidNonce(uint256 expected, uint256 supplied);
    error Expired();
    error InvalidSignature();
    error InvalidCall(uint256 index);
    error InsufficientExecutionGas(uint256 index);
    error CallFailed(uint256 index, bytes reason);

    event BatchExecuted(uint256 indexed nonce, address indexed executor, bytes32 callsHash);
    event NonceInvalidated(uint256 oldNonce, uint256 newNonce);

    modifier onlyDelegated() {
        if (address(this) == IMPLEMENTATION) revert NotDelegated();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    // Unlike constructor-based guards, this also protects fresh EOA storage.
    modifier nonReentrant() {
        AccountStorage storage state = _accountStorage();
        if (state.executing) revert ReentrantExecution();
        state.executing = true;
        _;
        state.executing = false;
    }

    receive() external payable {}

    function nonce() external view returns (uint256) {
        return _accountStorage().nonce;
    }

    /// @notice The EOA can send a transaction directly to itself to execute a batch.
    function execute(Call[] calldata calls)
        external
        payable
        onlyDelegated
        onlySelf
        nonReentrant
        returns (bytes[] memory results)
    {
        uint256 usedNonce = _accountStorage().nonce++;
        results = _execute(calls);
        emit BatchExecuted(usedNonce, msg.sender, hashCalls(calls));
    }

    /// @notice A sponsor executes a batch signed by the delegated EOA's private key.
    /// @param relayer Restrict submission to this address; zero permits any sponsor.
    /// @dev The signature binds msg.value (funding), each CALL's gas/value/data/target,
    /// the nonce, deadline, chain, EOA address, and this implementation address.
    function executeSigned(
        Call[] calldata calls,
        uint256 batchNonce,
        uint256 deadline,
        address relayer,
        bytes calldata signature
    ) external payable onlyDelegated nonReentrant returns (bytes[] memory results) {
        if (block.timestamp > deadline) revert Expired();
        if (relayer != address(0) && msg.sender != relayer) revert Unauthorized();
        AccountStorage storage state = _accountStorage();
        if (batchNonce != state.nonce) revert InvalidNonce(state.nonce, batchNonce);
        (address signer, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(batchDigest(calls, batchNonce, deadline, relayer, msg.value), signature);
        if (err != ECDSA.RecoverError.NoError || signer != address(this)) revert InvalidSignature();
        state.nonce++;
        results = _execute(calls);
        emit BatchExecuted(batchNonce, msg.sender, hashCalls(calls));
    }

    /// @notice Cancel all signatures with a nonce below newNonce using a self transaction.
    function invalidateNonce(uint256 newNonce) external onlyDelegated onlySelf nonReentrant {
        AccountStorage storage state = _accountStorage();
        uint256 oldNonce = state.nonce;
        if (newNonce <= oldNonce) revert InvalidNonce(oldNonce + 1, newNonce);
        state.nonce = newNonce;
        emit NonceInvalidated(oldNonce, newNonce);
    }

    function domainSeparator() public view returns (bytes32) {
        // Do not cache the deployed implementation's address or chain in an EOA domain.
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("TradingAccount7702"),
                keccak256("1"),
                block.chainid,
                address(this),
                bytes32(uint256(uint160(IMPLEMENTATION)))
            )
        );
    }

    function hashCalls(Call[] calldata calls) public pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            Call calldata item = calls[i];
            hashes[i] =
                keccak256(abi.encode(CALL_TYPEHASH, item.target, item.value, item.gasLimit, keccak256(item.data)));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function batchDigest(Call[] calldata calls, uint256 batchNonce, uint256 deadline, address relayer, uint256 funding)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(BATCH_TYPEHASH, hashCalls(calls), batchNonce, deadline, relayer, funding));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _execute(Call[] calldata calls) private returns (bytes[] memory results) {
        if (calls.length == 0) revert EmptyBatch();
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            Call calldata item = calls[i];
            // Self calls cannot recursively execute or invalidate signatures during a batch.
            if (item.target == address(0) || item.target == address(this) || item.gasLimit == 0) {
                revert InvalidCall(i);
            }
            bytes memory data = item.data;
            // Leave room for CALL overhead and EIP-150's 1/64 retention. A sponsor
            // cannot silently reduce the signed gas allowance. Any failure is atomic.
            if (gasleft() < item.gasLimit + item.gasLimit / 63 + 40_000) {
                revert InsufficientExecutionGas(i);
            }
            (bool success, bytes memory result) = item.target.call{value: item.value, gas: item.gasLimit}(data);
            if (!success) revert CallFailed(i, result);
            results[i] = result;
        }
    }

    function _accountStorage() private pure returns (AccountStorage storage state) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("perpdex.storage.TradingAccount7702")) - 1))
            & ~bytes32(uint256(0xff));
        assembly ("memory-safe") { state.slot := slot }
    }
}
