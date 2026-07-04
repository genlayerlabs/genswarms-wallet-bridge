// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpendRouter} from "../src/SpendRouter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

/// @notice Inheritable invariant suite — the spec §8 "router invariants" layer.
///         A concrete router's test contract inherits this, implements the
///         hooks, and gets the non-custodial invariants enforced for free.
///         Passing this suite is part of the package's adoption contract; the
///         base contract cannot enforce the beneficiary-binding rule in
///         Solidity, so THIS is where it is enforced.
abstract contract SpendRouterTestBase is Test {
    MockERC20Permit internal token;
    uint256 internal userPk = 0xA11CE;
    uint256 internal otherPk = 0xB0B;
    address internal user;
    address internal other;
    address internal keeper;

    function setUp() public virtual {
        token = new MockERC20Permit();
        user = vm.addr(userPk);
        other = vm.addr(otherPk);
        keeper = makeAddr("keeper");
        token.mint(user, 1_000_000e6);
        token.mint(other, 1_000_000e6);
        _deployRouter(address(token));
    }

    // ── hooks the concrete suite implements ────────────────────────────────
    function _deployRouter(address token_) internal virtual;
    function _router() internal view virtual returns (SpendRouter);
    /// Run the single action pranked as `asUser` with canned action args.
    /// Does NOT approve — the base prepares allowance via _approveAs first, so
    /// `vm.expectRevert` immediately before _executeAs targets the action call.
    function _executeAs(address asUser, uint256 amount, bytes32 orderId) internal virtual;
    /// Run the `...WithPermit` variant pranked as `submitter`; the claimed
    /// owner is vm.addr(ownerPk_), same canned action args.
    function _executeWithPermit(
        address submitter,
        uint256 ownerPk_,
        uint256 amount,
        bytes32 orderId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal virtual;
    /// Destination oracle: expected funds destination for canned args + user.
    function _expectedDestination(address user_) internal view virtual returns (address);
    /// Exact names of the state-changing functions the router may expose.
    function _allowedMutators() internal pure virtual returns (string[] memory);
    /// Artifact path for the ABI pin, e.g. "out/EchoSpendRouter.sol/EchoSpendRouter.json".
    function _artifactPath() internal pure virtual returns (string memory);

    // ── shared helpers ──────────────────────────────────────────────────────
    /// Delegation-lane batch leg 1: prepare the allowance. Kept separate from
    /// _executeAs so `vm.expectRevert` placed before _executeAs targets the
    /// action call, not this approve.
    function _approveAs(address asUser, uint256 amount) internal {
        vm.prank(asUser);
        token.approve(address(_router()), amount);
    }

    function _signPermit(uint256 pk, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, token.nonces(owner), deadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    // ── conservation + zero residual ────────────────────────────────────────
    function test_direct_conservation_and_zero_residual() public {
        address dest = _expectedDestination(user);
        uint256 u0 = token.balanceOf(user);
        _approveAs(user, 25e6);
        _executeAs(user, 25e6, keccak256("srtb-order-1"));
        assertEq(token.balanceOf(user), u0 - 25e6, "user debited exact amount");
        assertEq(token.balanceOf(dest), 25e6, "destination credited exact amount");
        assertEq(token.balanceOf(address(_router())), 0, "router holds nothing");
    }

    function test_permit_conservation_and_zero_residual() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userPk, address(_router()), 25e6, deadline);
        uint256 u0 = token.balanceOf(user);
        _executeWithPermit(keeper, userPk, 25e6, keccak256("srtb-order-2"), deadline, v, r, s);
        assertEq(token.balanceOf(user), u0 - 25e6);
        assertEq(token.balanceOf(_expectedDestination(user)), 25e6);
        assertEq(token.balanceOf(address(_router())), 0);
    }

    // ── credit recipient is derived from the signer, never the submitter ────
    function test_credit_recipient_is_signer_not_submitter() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userPk, address(_router()), 30e6, deadline);
        uint256 k0 = token.balanceOf(keeper);
        uint256 o0 = token.balanceOf(other);
        _executeWithPermit(keeper, userPk, 30e6, keccak256("srtb-order-3"), deadline, v, r, s);
        assertEq(token.balanceOf(_expectedDestination(user)), 30e6, "funds bound to signer");
        assertEq(token.balanceOf(_expectedDestination(keeper)), 0, "nothing bound to submitter");
        assertEq(token.balanceOf(keeper), k0, "submitter balance untouched");
        assertEq(token.balanceOf(other), o0, "third parties untouched");
    }

    // ── orderId idempotency, both lanes ─────────────────────────────────────
    function test_order_idempotent_direct() public {
        bytes32 orderId = keccak256("srtb-order-4");
        _approveAs(user, 5e6);
        _executeAs(user, 5e6, orderId);
        assertTrue(_router().orderConsumed(orderId));
        _approveAs(user, 5e6);
        vm.expectRevert(abi.encodeWithSelector(SpendRouter.OrderAlreadyConsumed.selector, orderId));
        _executeAs(user, 5e6, orderId);
    }

    function test_order_idempotent_permit() public {
        bytes32 orderId = keccak256("srtb-order-5");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userPk, address(_router()), 5e6, deadline);
        _executeWithPermit(keeper, userPk, 5e6, orderId, deadline, v, r, s);
        // Even with a fresh, valid second permit, the same orderId must revert.
        (uint8 v2, bytes32 r2, bytes32 s2) = _signPermit(userPk, address(_router()), 5e6, deadline);
        vm.expectRevert(abi.encodeWithSelector(SpendRouter.OrderAlreadyConsumed.selector, orderId));
        _executeWithPermit(keeper, userPk, 5e6, orderId, deadline, v2, r2, s2);
    }

    // ── argument floor checks ───────────────────────────────────────────────
    function test_zero_amount_reverts() public {
        vm.expectRevert(SpendRouter.ZeroAmount.selector);
        _executeAs(user, 0, keccak256("srtb-order-6"));
    }

    function test_zero_order_id_reverts() public {
        vm.expectRevert(SpendRouter.ZeroOrderId.selector);
        _executeAs(user, 5e6, bytes32(0));
    }

    // ── permit semantics ────────────────────────────────────────────────────
    function test_permit_frontrun_tolerance() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userPk, address(_router()), 25e6, deadline);
        // A front-runner consumes the signature directly against the token…
        token.permit(user, address(_router()), 25e6, deadline, v, r, s);
        // …and the keeper's submission still succeeds off the standing allowance.
        _executeWithPermit(keeper, userPk, 25e6, keccak256("srtb-order-7"), deadline, v, r, s);
        assertEq(token.balanceOf(_expectedDestination(user)), 25e6);
    }

    function test_permit_invalid_without_allowance_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        // Signature by `other`, claimed owner `user`: invalid permit, no allowance.
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherPk, address(_router()), 25e6, deadline);
        vm.expectRevert(SpendRouter.PermitRejected.selector);
        _executeWithPermit(keeper, userPk, 25e6, keccak256("srtb-order-8"), deadline, v, r, s);
    }

    function test_permit_cannot_pull_more_than_signed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userPk, address(_router()), 25e6, deadline);
        // Submitting a larger amount invalidates the signature (value is in the
        // struct hash) and the allowance path can't cover it either.
        vm.expectRevert(SpendRouter.PermitRejected.selector);
        _executeWithPermit(keeper, userPk, 26e6, keccak256("srtb-order-9"), deadline, v, r, s);
    }

    // ── ABI pin: single action, no owner/pause/upgrade/rescue/execute ───────
    function test_abi_pin_single_action_no_admin_surface() public view {
        string memory json = vm.readFile(_artifactPath());
        string[] memory allowed = _allowedMutators();
        uint256 found;
        uint256 i;
        while (vm.keyExistsJson(json, string.concat(".abi[", vm.toString(i), "]"))) {
            string memory base = string.concat(".abi[", vm.toString(i), "]");
            string memory typ =
                abi.decode(vm.parseJson(json, string.concat(base, ".type")), (string));
            require(
                keccak256(bytes(typ)) != keccak256("receive")
                    && keccak256(bytes(typ)) != keccak256("fallback"),
                "router must not have receive/fallback"
            );
            if (keccak256(bytes(typ)) == keccak256("function")) {
                string memory mut = abi.decode(
                    vm.parseJson(json, string.concat(base, ".stateMutability")), (string)
                );
                require(
                    keccak256(bytes(mut)) != keccak256("payable"),
                    "router must not have payable functions"
                );
                if (keccak256(bytes(mut)) == keccak256("nonpayable")) {
                    string memory name =
                        abi.decode(vm.parseJson(json, string.concat(base, ".name")), (string));
                    bool ok = false;
                    for (uint256 j = 0; j < allowed.length; j++) {
                        if (keccak256(bytes(name)) == keccak256(bytes(allowed[j]))) ok = true;
                    }
                    require(ok, string.concat("unexpected state-changing function: ", name));
                    found++;
                }
            }
            i++;
        }
        assertEq(found, allowed.length, "state-changing function count must match pin");
    }
}
