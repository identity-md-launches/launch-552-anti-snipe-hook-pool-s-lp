# Stateful test coverage

These suites extend the existing unit and integration tests without replacing them.
Both use 256 invariant runs of 128 calls, configured in Solidity comments. Only the
listed handler actions are targeted. Unexpected reverts fail the run; expected
failure paths check the exact custom error. No fork, environment mutation, new
dependency, or configuration change is required.

`AntiSnipeTokenInvariant.t.sol` mixes transfers, approvals, delegated transfers,
revocations, overdrafts, and invalid recipients across four holders. Independent
balance and allowance ledgers must match every holder after every action. The sum
of balances and total supply must remain exactly one billion tokens. Separate
examples pin zero, one unit, full supply, self-transfer, infinite approval,
revocation, and allowance rollback after a failed delegated transfer.

`AntiSnipeSequenceInvariant.t.sol` uses the existing production deployment fixture,
real PoolManager, and vendored settlement routers. Two pools can initialize at
different times. Three traders swap in both directions with exact input or exact
output, interleaved with time advances, fee collection, liquidity round trips,
duplicate initialization, and unauthorized callback/fee-update attempts.

Each production pool has a reference pool with the same price and liquidity. The
reference has no callbacks: its nonzero hook address has no permission bits, and
the test impersonates that address solely to set its stored LP fee to the required
1% or 0.3%. Production swaps always go through the real hook. Trade deltas, price,
ticks, LP fee growth, and liquidity proceeds must match the reference. This checks
actual fee execution through an independent path, including the override flag and
fee units, rather than trusting a returned quote alone.

After each action, each initialization deadline must equal the independently
recorded deadline; uninitialized pools must reject quotes. Swaps cannot write hook
storage or change the production pool's stored LP fee. Settlement deltas form a
reserve ledger checked against the manager's actual balances. All tokens must be
accounted for among the fixture, handler, traders, and manager, with no hook or
router custody and no outstanding manager deltas. Liquidity round trips use a
separate empty position so prior LP earnings cannot disguise rounding profit.

The stateful pool campaign keeps baseline liquidity present and bounds each trade
to 100 tokens, keeping execution within the funded range. The existing integration
suite covers full withdrawal. Conservation assumes the explicitly modeled calls;
it does not claim ERC-20 tokens cannot be transferred directly to the hook.

Run with `forge build` and `forge test`. To keep local artifacts in disposable
scratch space, append `--out test/scratch/out --cache-path test/scratch/cache`.
