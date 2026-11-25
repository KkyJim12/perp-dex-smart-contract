// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockUSDC} from "../../src/MockUSDC.sol";

contract AtlasTransferMock is MockUSDC {
    address public blockedRecipient;
    bool public chargeFee;
    bool public falseReturn;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;

    function setBlocked(address recipient) external {
        blockedRecipient = recipient;
    }

    function setChargeFee(bool value) external {
        chargeFee = value;
    }

    function setFalseReturn(bool value) external {
        falseReturn = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blockedRecipient, "Recipient blocked");
        if (reentryTarget != address(0)) (reentrySucceeded,) = reentryTarget.call(reentryData);
        bool ok = super.transfer(to, amount);
        return falseReturn ? false : ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (chargeFee) _burn(to, 1);
        return ok;
    }
}
