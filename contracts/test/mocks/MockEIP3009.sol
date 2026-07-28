// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only EIP-3009 token used by the Elixir anvil tamper test.
///         Its signature checks mirror Circle's externally visible rules:
///         v is 27/28, s is low, and the recovered signer is `from`.
contract MockEIP3009 {
    string public constant name = "USDC";
    string public constant version = "2";

    uint256 private constant _SECP256K1_HALF_ORDER =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationState[from][nonce], "authorization used");
        require(signature.length == 65, "invalid signature length");

        require(
            _recover(from, to, value, validAfter, validBefore, nonce, signature) == from,
            "invalid signature"
        );

        uint256 balance = balanceOf[from];
        require(balance >= value, "insufficient balance");
        authorizationState[from][nonce] = true;
        unchecked {
            balanceOf[from] = balance - value;
        }
        balanceOf[to] += value;
    }

    function _recover(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) private view returns (address) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                        from,
                        to,
                        value,
                        validAfter,
                        validBefore,
                        nonce
                    )
                )
            )
        );

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        require(v == 27 || v == 28, "invalid signature v");
        require(uint256(s) <= _SECP256K1_HALF_ORDER, "invalid signature s");
        return ecrecover(digest, v, r, s);
    }
}
