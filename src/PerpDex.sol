// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ⚠️ Adjust import path / type names to your actual fhEVM / Zama SDK
import {TFHE, euint64, ebool} from "lib/fhevm/TFHE.sol";

contract PerpDEXPrivateEngine {
    using TFHE for euint64;
    using TFHE for ebool;

    // ------------------
    // Ownership / Access
    // ------------------
    address public owner;
    address public relayer; // same relayer address used in PerpDEXPublic

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RelayerSet(address indexed oldRelayer, address indexed newRelayer);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "Not relayer");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function setRelayer(address _relayer) external onlyOwner {
        emit RelayerSet(relayer, _relayer);
        relayer = _relayer;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ------------------------
    // Encrypted Position Store
    // ------------------------

    struct EncPosition {
        // 🔓 minimal readable info
        bytes32 id;     // position id (only thing user/others can see)
        address user;   // owner (needed to sync with DB / UI)
        bool isLong;    // direction (can also be encrypted if you really want)

        // 🔒 encrypted fields
        euint64 margin;      // net margin (scaled, e.g. USDT*1e6)
        euint64 leverage;    // leverage as integer
        euint64 size;        // position size (scaled)
        euint64 entryPrice;  // 1e8
        euint64 liqPrice;    // 1e8
        euint64 tp;          // 1e8 (0 if none)
        euint64 sl;          // 1e8 (0 if none)

        // status
        bool isClosed;       // plain boolean is fine
    }

    // positionId -> encrypted position
    mapping(bytes32 => EncPosition) private positions;

    event EncryptedPositionStored(bytes32 indexed id, address indexed user);
    event EncryptedPositionClosed(bytes32 indexed id);

    // --------------------------
    // Store / Update (Relayer)
    // --------------------------

    /**
     * @notice Store a new encrypted position.
     * @dev All euint64/ebool values must already be ciphertexts produced off-chain
     *      with the fhEVM public key (using Zama SDK).
     *
     *  This function should be called right after `lockMarginForPosition` on
     *  PerpDEXPublic, using the same `positionId` & `user`.
     */
    function storeEncryptedPosition(
        bytes32 id,
        address user,
        bool isLong,
        euint64 encMargin,
        euint64 encLeverage,
        euint64 encSize,
        euint64 encEntryPrice,
        euint64 encLiqPrice,
        euint64 encTp,
        euint64 encSl
    ) external onlyRelayer {
        require(user != address(0), "Bad user");
        require(positions[id].user == address(0), "Position exists");

        positions[id] = EncPosition({
            id: id,
            user: user,
            isLong: isLong,
            margin: encMargin,
            leverage: encLeverage,
            size: encSize,
            entryPrice: encEntryPrice,
            liqPrice: encLiqPrice,
            tp: encTp,
            sl: encSl,
            isClosed: false
        });

        emit EncryptedPositionStored(id, user);
    }

    /**
     * @notice Mark position as closed (after settlement in PerpDEXPublic).
     */
    function markPositionClosed(bytes32 id) external onlyRelayer {
        EncPosition storage p = positions[id];
        require(p.user != address(0), "Unknown position");
        require(!p.isClosed, "Already closed");

        p.isClosed = true;
        emit EncryptedPositionClosed(id);
    }

    // -----------------------------------------
    // 🔍 Encrypted TP/SL & Liquidation Checks
    // -----------------------------------------
    // These are what your keeper/relayer calls instead of reading TP/SL/liq.

    /**
     * @notice Check TP/SL triggers using FHE-comparisons.
     * @param id        position id
     * @param markPrice1e8  current oracle mark price, scaled to 1e8
     * @return hitTp   true if TP should trigger
     * @return hitSl   true if SL should trigger
     *
     * Off-chain flow:
     *   - keeper gets plain oracle price (Pyth)
     *   - scales to 1e8
     *   - calls this function
     *   - receives boolean flags only (no numeric leaks)
     */
    function checkTpSl(
        bytes32 id,
        uint64 markPrice1e8
    ) external view onlyRelayer returns (bool hitTp, bool hitSl) {
        EncPosition storage p = positions[id];
        require(p.user != address(0), "Unknown position");
        if (p.isClosed) {
            return (false, false);
        }

        // Convert plain price to encrypted
        euint64 encMark = TFHE.asEuint64(markPrice1e8);

        // If TP/SL were disabled, enc value would be zero; we can treat zero as "no TP/SL"
        ebool hasTp = TFHE.gt(p.tp, TFHE.asEuint64(0));
        ebool hasSl = TFHE.gt(p.sl, TFHE.asEuint64(0));

        ebool condTp;
        ebool condSl;

        if (p.isLong) {
            // Long:
            //  - TP if mark >= TP
            //  - SL if mark <= SL
            condTp = TFHE.and(hasTp, TFHE.ge(encMark, p.tp));
            condSl = TFHE.and(hasSl, TFHE.le(encMark, p.sl));
        } else {
            // Short:
            //  - TP if mark <= TP
            //  - SL if mark >= SL
            condTp = TFHE.and(hasTp, TFHE.le(encMark, p.tp));
            condSl = TFHE.and(hasSl, TFHE.ge(encMark, p.sl));
        }

        // Decrypt to plain bool for the relayer/keeper
        // ⚠ depending on your fhEVM configuration, decrypt may require special permissions.
        hitTp = TFHE.decrypt(condTp);
        hitSl = TFHE.decrypt(condSl);
    }

    /**
     * @notice Check if position is liquidatable using encrypted comparisons.
     * @param id            position id
     * @param markPrice1e8  oracle price scaled to 1e8
     * @return shouldLiq    true if liquidation condition is met
     *
     * Long:
     *  - liq if mark <= liqPrice
     * Short:
     *  - liq if mark >= liqPrice
     */
    function checkLiquidation(
        bytes32 id,
        uint64 markPrice1e8
    ) external view onlyRelayer returns (bool shouldLiq) {
        EncPosition storage p = positions[id];
        require(p.user != address(0), "Unknown position");
        if (p.isClosed) {
            return false;
        }

        euint64 encMark = TFHE.asEuint64(markPrice1e8);

        ebool cond;
        if (p.isLong) {
            cond = TFHE.le(encMark, p.liqPrice);
        } else {
            cond = TFHE.ge(encMark, p.liqPrice);
        }

        shouldLiq = TFHE.decrypt(cond);
    }

    // -------------
    // View Helpers
    // -------------

    /**
     * @notice Returns minimal, NON-SENSITIVE info for UI/DB.
     * @dev No numeric values are returned, only id/user/isLong/isClosed.
     *      All prices/margins/size remain fully encrypted.
     */
    function getPositionMeta(bytes32 id)
        external
        view
        returns (address user, bool isLong, bool isClosed)
    {
        EncPosition storage p = positions[id];
        return (p.user, p.isLong, p.isClosed);
    }
}
