# genswarms-delegated-spend

Wallet-native delegated spending for GenSwarms products (Base + USDC + Telegram
+ deterministic Elixir object brain). Two lanes over one contract path:

- **Permit lane (M1):** one EIP-2612 signature per payment — gasless for the user.
- **Delegation lane (M2):** ERC-7710 standing delegation with caveats — one-tap.

**Generic as a package, never generic as a deployed authority:** every consuming
app deploys its own immutable `SpendRouter` subclass with exactly one typed
money-moving action. No shared deployed contracts.

Design spec: MicroMarkets `docs/superpowers/specs/2026-07-04-delegated-spend-package-design.md`.
Adoption contract (§3.2 of the spec): concrete router + funds destination +
intent calls + storage adapter + config/deploys. `contracts/src/examples/EchoSpendRouter.sol`
is the reference consumer; its test suite is the template.

No gambling terminology anywhere in this package (naming rule, legal).
