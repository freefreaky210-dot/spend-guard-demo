# SpendGuard Hook — ERC-7579 demo module

A clean-room demo of the thing I sell: **on-chain guardrails for smart accounts.**

`SpendGuardHook` is an ERC-7579 **hook module** (module type 4). Once installed on a smart account, the account routes every execution through the hook's `preCheck` first. The hook enforces two rules before any value moves:

1. **Target allowlist** — the account can only call contracts/addresses the owner approved.
2. **Daily spending cap** — total value out per day cannot exceed a limit the owner set. The cap counts native value **and** the amount inside any ERC20 `transfer` call, so splitting value across native sends and token transfers doesn't get around it.

If a check fails, `preCheck` reverts and the execution never happens. This is the enforcement pattern behind agent wallets and Smart Sessions policies: *an agent (or a dApp, or a session key) can act freely inside the lines — and physically cannot act outside them.*

## Why this exists

ERC-4337 / ERC-7579 modular accounts are where wallet UX is going, and the scarce skill is writing the modules that keep them safe. This repo is the public proof asset: small, readable, tested, honest about its simplifications.

## Run it

```bash
forge test
```

Foundry only — the test suite is dependency-free (minimal cheatcode harness, no forge-std), so it runs anywhere `forge` does.

## Layout

| File | What it is |
|---|---|
| `src/SpendGuardHook.sol` | The module. Install config, `preCheck`/`postCheck` enforcement, account-managed limit/allowlist updates, status views. |
| `src/MockSmartAccount.sol` | Minimal account stand-in that routes executions through the hook the way a real ERC-7579 account does. **Demo only — not a production account** (no EntryPoint, no signature validation). |
| `src/MockERC20.sol` | Toy token for the transfer-counting tests. |
| `test/SpendGuardHook.t.sol` | 11 tests: install lifecycle, native + token spend accounting against one shared cap, allowlist rejection, daily window reset, config permissions, uninstall/reinstall. |
| `LISTING.md` | Verified runbook for listing the module in the Rhinestone Module Registry (ERC-7484): registry address, exact registration signatures, resolver requirement, step-by-step commands, cost table. |

## Threat model (what the module is for)

- **Compromised or over-eager session key / AI agent:** bounded by the daily cap and the allowlist — worst case inside one day is the cap, and only to approved targets.
- **Prompt-injected agent trying to drain to an attacker address:** target isn't allowlisted → blocked, regardless of amount.
- **Slow-drip exfiltration:** the cap is per-day and cumulative across native + token transfers, so dripping doesn't accumulate past the limit.

## Honest simplifications (read this before judging the code)

- **Normalized hook payload.** A production ERC-7579 account passes the hook its raw `execute()` calldata (or the UserOperation in validation-time checks). This demo's mock account passes `abi.encode(target, callData)`. The enforcement logic — allowlist, cap accounting, window reset — is the real logic; only the payload decoding differs.
- **ERC20 accounting covers `transfer`**, not `transferFrom`/`approve` flows; a production policy adds those selectors and handles fee-on-transfer tokens by measuring balance deltas in `postCheck`.
- **The mock account is not a wallet.** The production path is installing this hook on a real modular account (Safe via the Safe7579 adapter, Kernel, Nexus) — the module interface is the standard one, so it ports directly.
- **Smart Sessions variant:** the same policy logic (caps, allowlists, windows) is what a session policy enforces for Smart Sessions; the integration surface differs (policy checks during session validation). Ask me about that version.

## Next steps (roadmap)

- [ ] Port to a live Safe + Safe7579 deployment on Sepolia, driven by a real UserOperation through a bundler + paymaster.
- [ ] Smart Sessions policy version of the same rules.
- [x] Register in the Rhinestone Module Registry — **done on Sepolia** (2026-10-20, see LISTING.md for the verified record); Base mainnet listing pending funding.

---

*Built as a portfolio/proof piece. Clean-room: no proprietary code from any client or personal project is included.*
