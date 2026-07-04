// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20Permit} from "./MockERC20Permit.sol";

/// @notice transferFrom lies: returns false without moving funds.
contract ReturnFalseToken is MockERC20Permit {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @notice Fee-on-transfer: destination receives amount - 1.
contract FeeOnTransferToken is MockERC20Permit {
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        super.transferFrom(from, to, amount);
        // burn 1 unit out of the destination — simulates a transfer fee
        balanceOf[to] -= 1;
        return true;
    }
}

/// @notice Reentrant: on the first transferFrom, calls back into an arbitrary
///         target with an arbitrary payload (swallowing its revert), then
///         proceeds normally.
contract ReentrantToken is MockERC20Permit {
    address public attackTarget;
    bytes public attackPayload;
    bool internal reentered;

    function setAttack(address target, bytes calldata payload) external {
        attackTarget = target;
        attackPayload = payload;
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        if (attackTarget != address(0) && !reentered) {
            reentered = true;
            (bool ok,) = attackTarget.call(attackPayload);
            ok; // swallow — the router invariants must hold regardless
        }
        return super.transferFrom(from, to, amount);
    }
}
