# AntiSnipe

An immutable Uniswap v4 hook that charges a **1% LP fee for the first hour after each pool initializes**, then **0.3% from the exact one-hour boundary onward**. There is no owner, pause, upgrade, fee setter, allowlist, or keeper.

## Contracts and behavior

- `src/AntiSnipeHook.sol`: takes exactly one constructor argument, `IPoolManager manager`. Records `antiSnipeEndsAt[poolId] = block.timestamp + 3600` in `afterInitialize`. This one-time deadline is the hook's only mutable state; repeat initialization is rejected. `beforeSwap` reads it and returns a zero delta and the appropriate fee with `LPFeeLibrary.OVERRIDE_FEE_FLAG`.
- `src/AntiSnipeToken.sol`: **AntiSnipe (SNIPE)**, an ordinary OpenZeppelin ERC-20 with no constructor arguments, 18 decimals, and exactly **1,000,000,000 tokens (10^27 minor units)** minted to its deployer. No subsequent mint, burn, owner, pause, tax, blocklist, or upgrade interface.
- `src/HookFlags.sol`: permission helpers for deployment/admission tooling.
- `script/MineHook.s.sol`: read-only CREATE2 salt/address calculation with explicit arguments. It sends no transactions and reads no environment variables.

| Elapsed time since pool initialization | LP fee | v4 fee units |
| --- | --- | --- |
| 0 through 3,599 seconds | 1% | 10,000 |
| 3,600 seconds and later | 0.3% | 3,000 |

The fee applies identically to both swap directions, exact input and exact output, every router/sender, and arbitrary hook data. Pools sharing this hook have independent deadlines keyed by the complete `PoolId`. The clock starts when the pool initializes, not when the hook deploys, liquidity arrives, or the first swap occurs. Timestamp zero is supported.

The hook requires `key.fee == 0x800000`, the dynamic fee flag, and `key.hooks == address(this)`. Static-fee pools are rejected. The per-swap return follows Uniswap's [dynamic-fee mechanism](https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees) and [LPFeeLibrary](https://github.com/Uniswap/v4-core/blob/a7cf038cd568801a79a9b4cf92cd5b52c95c8585/src/libraries/LPFeeLibrary.sol). It does **not** call `updateDynamicLPFee`: the manager's stored LP fee remains its initial zero. Indexers should use the effective fee in PoolManager swap events or compute it from the deadline, rather than infer it from slot0. Protocol fees configured by the PoolManager are separate from this LP fee schedule.

## Reproducible local checks

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimization with 200 runs, and no CBOR metadata. FFI and filesystem cheatcode permissions are disabled. Foundry and the pinned compiler must already be installed; all Solidity dependencies are ordinary files under `lib/`, requiring no network or submodules. `DEPENDENCIES.json` records exact upstream commits and SHA-256 hashes for the vendored files. Source subsets and license files are retained without modifying upstream source.

The delivered tests deploy a real local PoolManager and CREATE2-deploy the actual hook at a valid permission address. They cover:

- Initialization selectors, permission bits, missing hook code, invalid manager/keys, unauthorized callbacks, disabled callbacks, and duplicate initialization.
- Initialization-time, 3,599/3,600/3,601-second boundaries, timestamp zero, long elapsed times, independent pools, and storage-write-free swap callbacks.
- Actual swaps compared against equivalent static-fee pools, both directions and swap modes, with fuzzed times and amounts; accrued LP fees; complete liquidity withdrawal and token conservation; invalid price limits and failed settlement rollback.
- Token supply, metadata, transfers, allowances, invalid transfers, absence of administrative/mint selectors, and runtime opcode scans matching the supplied admission definitions.

The supplied protected tests consume externally attested creation code. Local tests exercise their relevant assertions directly; independent admission and fork rehearsal remain separate checks.

## Deployment parameters and procedure

No production chain, PoolManager, quote currency, factory, price, liquidity amount, or liquidity range has been selected. The network deployer must supply and verify these values. There are no hardcoded chain addresses.

| Parameter | Required value or responsibility |
| --- | --- |
| Hook artifact | `src/AntiSnipeHook.sol:AntiSnipeHook` |
| Hook constructor | `abi.encode(IPoolManager(poolManager))`; a deployed, trusted v4 PoolManager |
| Token artifact | `src/AntiSnipeToken.sol:AntiSnipeToken`; empty constructor arguments |
| Hook permission bits | `AFTER_INITIALIZE \| BEFORE_SWAP` = **0x1080 (4224)**; all other bits off |
| Address check | `uint160(hookAddress) & 0x3fff == 0x1080` |
| Pool fee field | **0x800000 (8388608)** exactly; do not put 3,000 or 10,000 here |
| Currencies | Numerically sorted currency addresses; select a standard quote asset |
| Tick spacing | A valid spacing chosen by the launcher; tests use 60 |
| Initial price | Nonzero valid `sqrtPriceX96`, accounting for currency order and decimals; tests use `2^96` |
| Liquidity | Launcher selects amounts/range and performs settlement through compatible v4 tooling |

1. Verify the target chain supports the PoolManager's Cancun/transient-storage requirements. Confirm the configured PoolManager deployment and the factory's actual CREATE2 deployer address.
2. Build with the pinned configuration. Compute creation code as `type(AntiSnipeHook).creationCode || abi.encode(poolManager)`. Mine the salt for the **actual CREATE2 deployer**, manager argument and exact bytecode. A change to any of these, including compiler settings, changes the predicted address.
3. The read-only mining helper can be run with explicit addresses:

   ```sh
   forge script script/MineHook.s.sol:MineHook \
     --sig 'run(address,address)' <POOL_MANAGER> <CREATE2_DEPLOYER>
   ```

   Use a target-chain fork (`--fork-url <RPC_URL>`) to check existing code at candidate addresses. Without a fork this is an offline calculation; the deployer must separately confirm the returned address is unoccupied. The bounded upstream miner can fail if no salt is found; report/review that failure rather than weakening permission checks.

4. The launch factory deploys the token (receiving the entire supply), CREATE2-deploys the hook with the returned salt, and initializes its pool **in one transaction**, supplying the dynamic fee field. The initialization callback prevents initializing a predicted pool before the hook has code. After deployment, initialization is permissionless, so separating deployment and initialization allows another party to choose the initial price/start the clock first. The hook does not add a factory owner or caller allowlist.
5. Seed liquidity using the launcher's chosen configuration. Verify deployed bytecode, permission bits, `poolManager()`, token supply/recipient, the pool key, and `AntiSnipeWindowStarted`. In network launch metadata, represent the constructor argument as `"$poolManager"`; the chain's deployer resolves it. The network's separate manifest process produces `launch.json`.

## Assumptions and operations

“No other state changes” means the hook only records the deadline needed for the requested schedule. It has no counters, fee accrual ledger, token transfers, custom delta accounting, or swap-time writes. Ordinary token and PoolManager accounting still occur outside the hook. A minimal BaseHook was chosen instead of a fee-update base class to keep the per-swap override explicit and avoid extra manager state updates.

The configured manager is trusted to enforce v4's pool lifecycle and invoke callbacks honestly; checking that its address has code does not establish its authenticity. `BaseHook` authenticates **all** callbacks against the immutable manager. Only `afterInitialize` and `beforeSwap` are enabled. All return-delta flags are false. There are no external calls from the hook's callback logic, funds held intentionally, or administrative recovery paths. Tokens accidentally sent to the hook cannot be rescued.

The schedule uses the chain's timestamp, including its normal validator/sequencer timing constraints. The extra fee discourages early trading but does not prevent sniping, sandwiching, or swaps through other pools. Routers/frontends remain responsible for slippage, price limits, deadlines, and routing; the hook does not interpret user identity or hook data. Use standard supported currencies; this project does not adapt fee-on-transfer or rebasing tokens.

No maintenance transaction is needed at the one-hour boundary. Operators should monitor initialization and effective swap fees. Before release, the network deployer/reviewer is responsible for independent adversarial review, target-chain fork rehearsal, verifying contract sources/bytecode, and confirming launch parameters. Local tests do not establish production deployment safety. No deployment, broadcast, fork test, Slither/Mythril run, or independent audit is claimed by this project.

Configuration: BaseHook; `afterInitialize = true`, `beforeSwap = true`, all other permissions false; no shares, currency settler, safe-cast helper, transient storage, pause, or access-control role in the hook. The requested absence of an owner takes precedence over the reference generator's administrative-access options.
