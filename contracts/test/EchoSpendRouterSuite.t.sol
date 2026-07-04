// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SpendRouterTestBase} from "./SpendRouterTestBase.sol";
import {SpendRouter} from "../src/SpendRouter.sol";
import {EchoSpendRouter} from "../src/examples/EchoSpendRouter.sol";

/// @notice The package's genericity proof: EchoSpendRouter must pass the full
///         inheritable invariant suite. This file is also the adoption
///         template — a consuming app's suite looks exactly like this.
contract EchoSpendRouterSuiteTest is SpendRouterTestBase {
    EchoSpendRouter internal echo;
    address internal anchor = address(0xA4C402);
    bytes32 internal constant TOPIC = keccak256("echo-topic");

    function _deployRouter(address token_) internal override {
        echo = new EchoSpendRouter(token_, anchor, address(0));
    }

    function _router() internal view override returns (SpendRouter) {
        return echo;
    }

    function _executeAs(address asUser, uint256 amount, bytes32 orderId) internal override {
        vm.prank(asUser);
        echo.pay(TOPIC, amount, orderId);
    }

    function _executeWithPermit(
        address submitter,
        uint256 ownerPk_,
        uint256 amount,
        bytes32 orderId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal override {
        vm.prank(submitter);
        echo.payWithPermit(TOPIC, amount, orderId, vm.addr(ownerPk_), deadline, v, r, s);
    }

    function _expectedDestination(address user_) internal view override returns (address) {
        return echo.destinationFor(TOPIC, user_);
    }

    function _allowedMutators() internal pure override returns (string[] memory) {
        string[] memory names = new string[](2);
        names[0] = "pay";
        names[1] = "payWithPermit";
        return names;
    }

    function _artifactPath() internal pure override returns (string memory) {
        return "out/EchoSpendRouter.sol/EchoSpendRouter.json";
    }

    // ── Echo-specific pins ──────────────────────────────────────────────────
    function test_views() public view {
        assertEq(echo.token(), address(token));
        assertEq(echo.anchor(), anchor);
        assertEq(echo.delegationManager(), address(0));
        assertEq(echo.routerType(), keccak256("ECHO_SPEND_ROUTER"));
        assertEq(echo.version(), "0.1.0");
    }

    function test_destinations_differ_per_topic_and_beneficiary() public view {
        address a = echo.destinationFor(TOPIC, user);
        assertTrue(a != echo.destinationFor(keccak256("other-topic"), user));
        assertTrue(a != echo.destinationFor(TOPIC, other));
    }

    // Local re-declaration for vm.expectEmit (solc 0.8.20 has no qualified
    // `emit Contract.Event` syntax — that arrived in 0.8.21).
    event EchoPaid(
        bytes32 indexed topic, address indexed payer, address destination, uint256 amount, bytes32 orderId
    );

    function test_echo_paid_event() public {
        address dest = echo.destinationFor(TOPIC, user);
        vm.startPrank(user);
        token.approve(address(echo), 25e6);
        vm.expectEmit(true, true, false, true, address(echo));
        emit EchoPaid(TOPIC, user, dest, 25e6, keccak256("evt-order"));
        echo.pay(TOPIC, 25e6, keccak256("evt-order"));
        vm.stopPrank();
    }
}
