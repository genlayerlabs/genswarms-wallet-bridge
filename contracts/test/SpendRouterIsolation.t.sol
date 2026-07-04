// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpendRouter} from "../src/SpendRouter.sol";
import {EchoSpendRouter} from "../src/examples/EchoSpendRouter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

/// @notice Spec §8 "genericity proof" (cross-router isolation) and "blast
///         radius" (attacker-as-keeper) rows.
contract SpendRouterIsolationTest is Test {
    MockERC20Permit token;
    EchoSpendRouter routerA;
    EchoSpendRouter routerB;
    uint256 userPk = 0xA11CE;
    address user;
    address attacker = address(0xBAD);
    bytes32 constant TOPIC = keccak256("echo-topic");

    function setUp() public {
        token = new MockERC20Permit();
        routerA = new EchoSpendRouter(address(token), address(0xA4C401), address(0));
        routerB = new EchoSpendRouter(address(token), address(0xA4C402), address(0));
        user = vm.addr(userPk);
        token.mint(user, 1_000e6);
    }

    function _signPermit(address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(token.PERMIT_TYPEHASH(), user, spender, value, token.nonces(user), deadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(userPk, digest);
    }

    // ── cross-router isolation ──────────────────────────────────────────────
    function test_order_scope_is_per_instance() public {
        bytes32 orderId = keccak256("iso-order");
        vm.startPrank(user);
        token.approve(address(routerA), 10e6);
        routerA.pay(TOPIC, 10e6, orderId);
        // Same orderId on another instance is a DIFFERENT order (documented
        // scope: per router). Consumers must namespace order ids per router.
        token.approve(address(routerB), 10e6);
        routerB.pay(TOPIC, 10e6, orderId);
        // Replay on the same instance still reverts.
        token.approve(address(routerA), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(SpendRouter.OrderAlreadyConsumed.selector, orderId)
        );
        routerA.pay(TOPIC, 10e6, orderId);
        vm.stopPrank();
    }

    function test_permit_for_router_a_unusable_via_router_b() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(routerA), 25e6, deadline);
        // The EIP-2612 spender is part of the signed struct: router B's permit
        // call fails and B has no allowance.
        vm.prank(attacker);
        vm.expectRevert(SpendRouter.PermitRejected.selector);
        routerB.payWithPermit(TOPIC, 25e6, keccak256("iso-b"), user, deadline, v, r, s);
    }

    // ── attacker-as-keeper blast radius ─────────────────────────────────────
    function test_attacker_keeper_cannot_redirect_credit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(routerA), 25e6, deadline);
        // Attacker varies the unauthenticated action arg (topic): the spend
        // succeeds but lands at a destination still bound to the USER.
        bytes32 evilTopic = keccak256("attacker-topic");
        vm.prank(attacker);
        routerA.payWithPermit(evilTopic, 25e6, keccak256("iso-c"), user, deadline, v, r, s);
        assertEq(token.balanceOf(routerA.destinationFor(evilTopic, user)), 25e6);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(routerA.destinationFor(evilTopic, attacker)), 0);
    }

    function test_attacker_cannot_claim_to_be_the_user() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(routerA), 25e6, deadline);
        // Passing owner = attacker with the user's signature: permit is
        // invalid for that owner and the attacker has granted no allowance.
        vm.prank(attacker);
        vm.expectRevert(SpendRouter.PermitRejected.selector);
        routerA.payWithPermit(TOPIC, 25e6, keccak256("iso-d"), attacker, deadline, v, r, s);
    }
}
