// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract MockERC20PermitTest is Test {
    MockERC20Permit token;
    uint256 ownerPk = 0xA11CE;
    address owner;
    address spender = address(0x5BE7DE7);

    function setUp() public {
        token = new MockERC20Permit();
        owner = vm.addr(ownerPk);
        token.mint(owner, 100e6);
    }

    function _sign(uint256 pk, address owner_, address spender_, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                token.PERMIT_TYPEHASH(), owner_, spender_, value, token.nonces(owner_), deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_permit_sets_allowance_and_bumps_nonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerPk, owner, spender, 25e6, deadline);
        token.permit(owner, spender, 25e6, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), 25e6);
        assertEq(token.nonces(owner), 1);
    }

    function test_permit_replay_rejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerPk, owner, spender, 25e6, deadline);
        token.permit(owner, spender, 25e6, deadline, v, r, s);
        vm.expectRevert("MockERC20Permit: bad permit sig");
        token.permit(owner, spender, 25e6, deadline, v, r, s);
    }

    function test_permit_expired_rejected() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerPk, owner, spender, 25e6, deadline);
        vm.expectRevert("MockERC20Permit: permit expired");
        token.permit(owner, spender, 25e6, deadline, v, r, s);
    }

    function test_permit_wrong_signer_rejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(0xB0B, owner, spender, 25e6, deadline);
        vm.expectRevert("MockERC20Permit: bad permit sig");
        token.permit(owner, spender, 25e6, deadline, v, r, s);
    }

    function test_transfer_from_respects_allowance() public {
        vm.prank(owner);
        token.approve(spender, 10e6);
        vm.prank(spender);
        token.transferFrom(owner, spender, 10e6);
        assertEq(token.balanceOf(spender), 10e6);
        vm.prank(spender);
        vm.expectRevert("MockERC20Permit: allowance");
        token.transferFrom(owner, spender, 1);
    }
}
