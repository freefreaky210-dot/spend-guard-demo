# Listing SpendGuardHook in the Rhinestone Module Registry

*Registry mechanics verified 2026-10-20 against the registry's verified on-chain source (Sourcify) and live chain state — not from blog posts.*

## Verified facts

- **Registry (ERC-7484 singleton):** `0x000000000069E2a187AEFFb852bF3cCdC95151B2`
  Code presence checked on-chain at this address: **Ethereum mainnet ✓, Sepolia ✓, Base ✓** (same address on each).
- **Registration is permissionless.** No application, no approval queue. If the transaction succeeds, the module is listed.
- **Registration requires a resolver.** Every module record points at a `resolverUID`. A resolver is a contract implementing the registry's `IExternalResolver` interface (checked via ERC-165 `supportsInterface`). During `registerModule`, the registry calls the resolver's module-registration hook — so the resolver you register under must accept your module. **Using our own no-op resolver = nobody can block or condition our listing.**
- **Exact signatures (from the verified ABI):**
  - `registerResolver(address resolver)` → emits `NewResolver(uid, resolver)`; the UID is derived from the resolver record and read from this event.
  - `registerModule(bytes32 resolverUID, address moduleAddress, bytes metadata, bytes resolverContext)`
  - `findModule(address moduleAddress)` → view; the verification step.
  - Alternative one-shot path: `deployModule(bytes32 salt, bytes32 resolverUID, bytes initCode, bytes metadata, bytes resolverContext)` deploys via CREATE2 and registers in the same transaction. (Not used below — plain deploy + register is easier to debug step by step.)
- **`registerModule` validation (from source):** resolverUID must exist → module address must have contract code (`InvalidDeployment`) → module must not already be registered (`AlreadyRegistered`) → resolver hook runs → record stored with `sender = address(0)` on this post-deployment path.
- **Registration ≠ attestation.** A fresh listing has zero attestations. Attestations come later from security reviewers — that is normal for new modules and is a separate credibility step, not part of listing.

## The runbook (5 transactions)

Works identically on Sepolia and Base/mainnet — only `$RPC_URL` and the funding change.

```bash
export RPC_URL=<chain rpc>            # Sepolia or Base
export DEPLOYER_PK=<funded key>       # see "Who signs" below
REGISTRY=0x000000000069E2a187AEFFb852bF3cCdC95151B2
```

**0. Resolver (one-time).** Clone `rhinestonewtf/registry` (GPL-3.0) and deploy a minimal resolver implementing its `IExternalResolver` with every hook returning `true` (deployment-time tooling only — not part of this repo, keeps this repo clean-room). Deploy with `forge create`, note its address as `$RESOLVER`.

**1. Register the resolver**
```bash
cast send $REGISTRY "registerResolver(address)" $RESOLVER --rpc-url $RPC_URL --private-key $DEPLOYER_PK
# read the uid from the NewResolver event in the receipt -> export RESOLVER_UID=0x...
```

**2. Deploy SpendGuardHook**
```bash
forge create src/SpendGuardHook.sol:SpendGuardHook --rpc-url $RPC_URL --private-key $DEPLOYER_PK
# note the deployed address -> export MODULE=0x...
```
(Bytecode is 3,473 bytes → roughly 750–850k gas.)

**3. Register the module**
```bash
METADATA=$(cast abi-encode "f(string)" "SpendGuardHook v0.1.0 | ERC-7579 hook | daily spend cap + target allowlist" )
cast send $REGISTRY "registerModule(bytes32,address,bytes,bytes)" $RESOLVER_UID $MODULE $METADATA 0x --rpc-url $RPC_URL --private-key $DEPLOYER_PK
```
(Metadata is free-form bytes for downstream tooling; the string above is a human-readable descriptor. Point it at the public repo URL once the repo is published.)

**4. Verify the listing**
```bash
cast call $REGISTRY "findModule(address)" $MODULE --rpc-url $RPC_URL
# returns the ModuleRecord if listed. Note: cast's decoded printing of the
# nested struct is unreliable — decode the raw return instead: word 1 (after
# the 0x20 offset) = resolverUID, word 2 = sender (0x0 on this path), then the
# metadata bytes. Verified working in the 2026-10-20 fork rehearsal.
```

**5. Record it.** Put chain, module address, resolver UID, and both tx hashes in this file's log below.

## Costs (estimates — confirm at execution time)

| Chain | Cost | Notes |
|---|---|---|
| Sepolia | **$0** | Test ETH from a faucet. Full rehearsal of all 5 steps. |
| Base | typically **< $1 total** | ~1.3M gas across all txs at Base's usual fee levels. |
| Ethereum mainnet | **gas-dependent** (≈800k gas for the deploy alone) | A few dollars in calm conditions, more when the network is busy. Highest visibility. |

## Who signs

The deployer key funds and signs these transactions. Two properties make a fresh, dedicated deployer wallet safe here: `SpendGuardHook` has **no owner/admin functions** (the deployer controls nothing after deployment), and the no-op resolver's ownership is transferable via `transferResolverOwnership`. Recommendation: fresh wallet for the listing work; on mainnet paths it only ever holds the few dollars of gas it needs.

## Execution log

| Date | Chain | Module address | Resolver UID | Deploy tx | Register tx |
|---|---|---|---|---|---|
| 2026-10-20 | **Sepolia (live)** | 0x6BA337A13E5006a26Fdf5eCef76A0Ad9b9218BcD | 0x4768a6961a6580d0a92e1bb9aa5db0bc60001b4e65d5cd5e701b19a8cbd1fdcb | (deployer nonce 2) | 0x4551b8a893c3b857687d46bc0467efa133a5d40a6c3ca491ebd6e634e1748aa2 (status ✓; record raw-decoded: UID ✓, sender 0x0 ✓, metadata ✓). Resolver: 0xF1753dFfae4c45D796E3130ec6Ddfd5Ef0A7a2Bd. Funded by pk910 PoW faucet claim 0xbd9f0fb380235bc8a7a418a49e0569618a325b31a71f18a02d793bf66575d996 (0.058 SepETH). |
| 2026-10-20 | Sepolia **fork** (rehearsal vs real registry state; fork-local addresses/txs) | 0x7c74A848463a9a1C0370E3044b49c9c9f9f7a2B9 | 0xc16aa056e5b95ac2ca45d403857861f1440c9d25b16745a9cad80c24d9706e04 | fork-local | 0x78682f799b23baf5493025f33c73ca4c40dbefcdbeab5da2d8b03240b460970d (status ✓, record decoded: UID ✓, sender 0x0 ✓, metadata ✓) |
| — | — | — | — | — | — |
