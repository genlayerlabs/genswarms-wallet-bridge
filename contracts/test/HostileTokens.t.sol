// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpendRouter} from "../src/SpendRouter.sol";
import {EchoSpendRouter} from "../src/examples/EchoSpendRouter.sol";
import {ReturnFalseToken, FeeOnTransferToken, ReentrantToken} from "./mocks/HostileTokens.sol";

/// @notice Pins _routeSpend's behavior under hostile tokens (spec §8, router
///         invariants row). USDC is none of these; the point is that a wrong
///         token config degrades to a clean revert, never a silent partial
///         spend.
contract HostileTokensTest is Test {
    address anchor = address(0xA4C402);
    address user = address(0xA11CE7);
    bytes32 constant TOPIC = keccak256("echo-topic");

    function test_return_false_token_reverts() public {
        ReturnFalseToken token = new ReturnFalseToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        vm.expectRevert(SpendRouter.SpendTransferFailed.selector);
        router.pay(TOPIC, 25e6, keccak256("hostile-1"));
        vm.stopPrank();
    }

    function test_fee_on_transfer_token_reverts() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        vm.expectRevert(SpendRouter.SpendTransferFailed.selector);
        router.pay(TOPIC, 25e6, keccak256("hostile-2"));
        vm.stopPrank();
    }

    function test_reentrant_same_order_cannot_replay() public {
        ReentrantToken token = new ReentrantToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        bytes32 orderId = keccak256("hostile-3");
        // Reentry attempts the SAME order — must hit OrderAlreadyConsumed
        // inside (the outer call consumed it before any external interaction);
        // the token swallows that revert and the outer spend completes exactly
        // once.
        token.setAttack(
            address(router), abi.encodeCall(EchoSpendRouter.pay, (TOPIC, 25e6, orderId))
        );
        vm.startPrank(user);
        token.approve(address(router), 100e6);
        router.pay(TOPIC, 25e6, orderId);
        vm.stopPrank();
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 25e6, "spent exactly once");
        assertEq(token.balanceOf(user), 75e6);
    }

    function test_reentrant_fresh_order_same_destination_reverts_outer() public {
        ReentrantToken token = new ReentrantToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        // Reentry lands a FRESH order at the same destination mid-flight. A
        // plain `pay` from the token's own context couldn't do that (it would
        // derive the TOKEN's destination and fail on allowance), so the attack
        // uses `payWithPermit` with a garbage signature riding the USER's
        // standing allowance through the front-run-tolerance branch — the
        // strongest reentrancy shape available. The outer exact-delivery check
        // then sees more than `amount` arrive and reverts the whole
        // transaction — no partial state survives.
        token.setAttack(
            address(router),
            abi.encodeCall(
                EchoSpendRouter.payWithPermit,
                (
                    TOPIC,
                    10e6,
                    keccak256("hostile-4b"),
                    user,
                    block.timestamp + 1 hours,
                    uint8(27),
                    bytes32(0),
                    bytes32(0)
                )
            )
        );
        vm.startPrank(user);
        token.approve(address(router), 100e6);
        vm.expectRevert(SpendRouter.SpendTransferFailed.selector);
        router.pay(TOPIC, 25e6, keccak256("hostile-4a"));
        vm.stopPrank();
        assertEq(token.balanceOf(user), 100e6, "nothing moved");
        assertFalse(router.orderConsumed(keccak256("hostile-4a")));
        assertFalse(router.orderConsumed(keccak256("hostile-4b")));
    }
}
