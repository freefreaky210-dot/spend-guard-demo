# Three Ways Session-Key Modules Leak Permissions

*For teams shipping session keys, agent wallets, or any "limited" key that can move money: the policy is the product. These are the first three patterns I check in every review — because each one turns a carefully scoped session into something close to a blank check.*

A session key is a capability token. The account owner signs once, and a lesser key — a dApp, a bot, an AI agent — gets to act within limits: this much value, to these contracts, until this time. Every word of that sentence is enforced by policy code, and policy code is where the leaks live. Not in exotic cryptography. In accounting.

## Leak 1: The silent approve

Most spending policies count what a session *transfers*. Approvals are not transfers, so they sail through — and an approval is a loaded weapon:

- The session calls `approve(attacker, uint256.max)` on a token the account holds. No value moved. Every transfer-based check passes.
- The attacker then calls `transferFrom` **whenever they like** — tomorrow, next month, after the session key has expired or been revoked. Revoking the session does nothing to the allowance; it lives on the token contract, not in your session system.
- Worst part: the eventual drain **never passes through the account's execution path at all**. No hook fires, no policy is consulted. The money leaves via a pull payment your module never sees.

Variants of the same hole: `increaseAllowance`, `setApprovalForAll` on NFT collections, and signed permits relayed by a third party.

**The fix:** treat approval-class calls as spend. When a session calls `approve`/`increaseAllowance`, count the approved amount against the session's cap *at approval time* — or ban those selectors for session keys outright and make approvals an owner-only action. If your policy can't see it, it isn't a limit.

## Leak 2: Target without selector

Allowlists are usually keyed on contract addresses: "the session may call the DEX router and the token." But an address is not a permission — a *function* is. Call any method on an allowlisted contract and the session inherits the whole surface:

- Allowlist a **token** for transfers, and the session also gets `approve` (see Leak 1).
- Allowlist a **router or aggregator**, and the session gets every swap path, every callback, and often a generic execution entry point that can be aimed at arbitrary contracts with arbitrary calldata — your allowlist just became a proxy to anywhere.
- Allowlist a **vault or account-adjacent contract**, and admin-flavored methods (pause, rescue, reconfigure, withdraw-to) may sit one selector away from the benign function you meant to permit.

**The fix:** permissions are *(target, selector)* pairs, never bare targets. A session allowed to swap gets the router's swap selectors — not its `multicall`, not its `execute`, not its admin surface. And any selector that itself dispatches arbitrary calls (`multicall`, `execute`, `aggregate`) gets treated as guilty until its arguments are inspected.

## Leak 3: Window games

"500 USDC per day" sounds like a hard bound. With a calendar window, it isn't:

- At 23:59 the session spends the full cap. At 00:01 the window resets and it spends the full cap again. **2× the intended limit inside two minutes**, no rule broken.
- The same shape repeats at every boundary — week, month, "per epoch." The longer the window, the bigger the burst an attacker (or a malfunctioning agent loop) can fire the moment it opens.
- Agents make this worse than humans do: a buggy agent doesn't drain an account slowly and noticeably. It retries at machine speed, and it will find your window boundary at 3 a.m.

**The fix:** rolling windows and per-transaction caps, working together. A trailing-24h accounting window has no cliff to burst across; a per-tx cap bounds any single action; a window cap bounds the total. Any one of the three alone has a shape that leaks — the combination is the actual control.

## How I build it — and where my own demo stands

I shipped a small ERC-7579 hook module, **SpendGuardHook**, as a public reference for this pattern: every execution is checked pre-flight against a target allowlist and a cumulative spend cap that counts native value *and* ERC20 `transfer` amounts against one budget. It's tested, and it's listed in the Rhinestone Module Registry on Sepolia. Mapped against the three leaks, honestly:

- **Approvals:** *roadmap, and the demo's sharpest known gap.* The current version counts `transfer` amounts; approval-counting (Leak 1's fix) is the next feature, and it's deliberately the headline item — a demo that hides its gaps teaches the wrong lesson.
- **Selectors:** the hook already inspects calldata at exactly the point where selector-level policy belongs (that's how it recognizes transfers). The demo ships target-level allowlisting for readability; *(target, selector)* pairs are the production configuration.
- **Windows:** the demo uses calendar-day windows — which means it has the bounded version of Leak 3 (worst case at a boundary is 2× the daily cap, never unbounded). Rolling windows are the production upgrade, and the accounting structure already supports swapping the window function.

That mapping is the review method in miniature: find where value can move *without being counted*, find where a permission is *broader than its name*, find where *time boundaries* multiply limits. If you're shipping session keys or agent wallets and want a second set of eyes on exactly these questions, that's the review I run — and the integration work I do after it.

— **Av** · modular smart account specialist (ERC-7579 · Smart Sessions · Safe/Kernel/Nexus)
*Demo + tests: SpendGuardHook (ERC-7579 hook module) · Registry listing: Sepolia, module `0x6BA337A13E5006a26Fdf5eCef76A0Ad9b9218BcD`*
