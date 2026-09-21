# Fables contracts research

Read-only contract investigation dated 2026-09-21. This is a source/state review, not an independent audit of the whole Fables protocol.

## Evidence boundaries

**Explorer verified source:** RobinScan explicitly reports Source Code Verified / Exact Match for RWA `0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080`, Ramp `0x08E52564Bad99E05a694b4809F397edcA417A080`, and native RWA `0xcA89f079AF00f752bfD3C345358Dc38d4d73e080`. Compiler v0.8.26+commit.8a97fa7a, optimizer 200 runs, Cancun. This is the explorer's verification claim, not an independent local compilation/bytecode comparison. Do not extend it to every older hook without fetching that address's code. Custom contracts carry SPDX UNLICENSED; explorer displays license -NA-. Public readability is not permission to copy source.

**State evidence:** no-argument explorer Read Contract pages expose actual values, but no pinned block is supplied. Current constants/authority below were observed September 21, 2026 around 05:20 UTC. Keeper transaction has a concrete block and receipt. Other numerical examples embedded in comments are not independent state reads.

**Pinned follow-up:** `chain-snapshot.json` records direct RPC reads at block **68,544,700**, enumerating 37 active pools. It includes current direction fees, caps, floor/config/poke state and treasury getters. Some newer ABI probes revert on older hooks; successful legacy getter results are stored separately rather than misreported as zero.

**Documentation:** official content lives in SPA bundle https://www.fables.fi/assets/DocsRoute-1lx2M5gG.js; routes https://www.fables.fi/docs/dynamic-fees, https://www.fables.fi/docs/contracts-and-addresses, https://www.fables.fi/docs/security and https://www.fables.fi/docs/fees-and-returns. Bare read of route often returns only SPA shell. `/sitemap.xml` also returned SPA shell, not real sitemap.

## Deployment registry

Chain ID documented as 4663. RPC https://rpc.mainnet.chain.robinhood.com.

Shared addresses, official docs:
- AccessManager: `0xA362D98B33A7bb5B5E2180a05f995A70FB404f30`
- Pool registry: `0x159A113E012593D9B3cC63ad45E30F0467e13Ef3`
- Uniswap PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`
- StateView: `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`
- Protocol fee controller: `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`
- Creator reward distributor: `0xc9ecc11728a4955b31f77c077b97fec521d78760`
- Treasury/claimFeeRecipient: `0x9F887B9930E9e716286333Bd8e291f64a8710F6f`

Market hooks documented:
- ETH/USDG `0x06a889870C8f83640D6816319f72e2aA579b6080`
- AAPL/USDG `0x70a9A88402989226847Ec122043CE5e7FF462080`
- GLD/USDG `0xB608a78761f179f7C56f15E7D13921B92F00a080`
- META/USDG `0x8AF95932eC4484fb10C641a4cBcf19a798cB2080`
- NVDA/USDG `0x66622f77B797D506e5376F7798b67ab288966080`
- SPY/USDG `0xA0E8fBFf13E24Af2b5e61A72800E08a161bDe080`
- TSLA/USDG `0x67D86050d22D574Df046F3D90F722045F714e080`
- NVDA/SPY `0x79576FBAD6e83915630BBB5D5658483F05532080`
- SPY/GLD `0xA4570C37590E45f0b06898123D4de16307A32080`
- Shared RWA `0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080`: AMC, AMZN, HIMS, SPCX, CRCL, GLXY, MSTR, MU against USDG.
- Shared Ramp `0x08E52564Bad99E05a694b4809F397edcA417A080`: CASHCAT, DJT, GME, MEME, PONS, AI, cbBTC, INDEX, MOO, ORBIO, UBIK, ZZZ against USDG, plus SPY/QQQ.
- Shared native non-calendar `0x594e8e6281eDf2d363a0293a50004Cf868E7a080`: ETH/AI, ETH/PONS, ETH/CASHCAT. Its exact variant source not inspected in this slice.
- Native RWA `0xcA89f079AF00f752bfD3C345358Dc38d4d73e080`: ETH/AMC. Source `FablesRWAETH` merely inherits RWA and native settlement overrides; it does not replace the RWA autonomous mathematics.

All explorer address links use https://robin.etherscan.io/address/ADDRESS#code. Active per-market pool IDs and token addresses are preserved in the [pinned chain snapshot](chain-snapshot.json). Particularly useful: UBIK/USDG `0x4aaa4f57bec2b6e67dac42909c8c4f9a6ddaf02bb63f8dcbbafb35316731d2a7`; NVDA/USDG `0x7990aad9e8fb048f49a155a7df5603db0366f0657035b78eb4196395cccb3dcd`; ETH/USDG `0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551`.

## Exact common fee resolution

Source: verified `FablesBaseHook.sol` in the [shared RWA hook's explorer source](https://robin.etherscan.io/address/0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080#code), especially `autonomousFee`, `pokeFee`, `_resolveFee`, `_setPoolBounds`.

All LP fee numbers are integer pips, fraction `fee / 1,000,000`; 100 pips = 0.01%, 50000 pips = 5%.

Let `A` be model fee, `P` persistent premium, `d` swap zeroForOne, `pd` premium direction, `C` per-pool cap, `F` configured floor. Define `B = A + (d == pd ? P : 0)`.
- No live nonzero override for this direction: `fee = min(B,C)`.
- Override fresh iff `expiry > block.timestamp`, not >=.
- Select `q = zeroForOne ? fee0For1 : fee1For0`.
- If fresh and q != 0, `D = floor(min(B,C) * (10000 - 5000) / 10000)`; `fee = min(C, max(q,F,D))`.

Thus stored/logged poke may differ from actual charged fee. Runtime floor tracks CURRENT autonomous curve, premium and CURRENT cap; it is not only checked at posting time. Discount floor rounds DOWN, so odd-pip B allows the one-pip rounding edge implied by integer division. `autonomousFee` is pre-cap, pre-poke and includes direction premium; `currentFee` includes everything. Both use a zero-amount probe (potential size-dependent models would therefore need care; inspected Ramp/RWA are not size dependent).

`pokeFee(poolId,fee0For1,fee1For0,ttl)`:
- configured pool required;
- both sides zero rejected;
- each nonzero side individually must lie `[F,C]`;
- zero means leave that direction autonomous, not zero-fee;
- ttl in `[1,259200]` seconds;
- entire struct replaced; restate other side to retain it;
- new expiry now+ttl;
- symmetric poke can flatten persistent premium temporarily, subject to runtime discount floor;
- no spread-pattern/cross-side restriction;
- clearPoke deletes both sides, configured pool required.

`setPoolAsymmetry` permits `P <= C-F`, and `_setPoolBounds` rechecks same invariant whenever floor/cap move. All config calls must reference this hook in PoolKey. Floor >=100; cap <= immutable deployment max. RWA and Ramp no-argument read pages both report immutable max50000, max discount5000bps, ttl259200, min100.

`beforeSwap` returns ZERO_DELTA and `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG`; only beforeInitialize/beforeSwap permissions. beforeInitialize requires dynamic marker, configured cap and native allowance for native pools. No on-chain external oracle read in these inspected model paths.

## RWA autonomous model

Source: FablesRWA.sol, CalendarLib.sol and SessionLib.sol.

FloorConfig ordered fields: `(openFloor O, overnightFloor N, closedFloor X, spikeMult M, closedSpike Sx, descentWindow W, closeFloor H, closeBefore U, closeAfter V)`.

Session floor:
- CLOSED → X;
- OVERNIGHT → N;
- OPEN with W=0 or elapsed `e >= W` → O;
- OPEN descent: choose S=Sx when previous ET civil date was fully closed under weekend/holiday/override rules, else S=N*M. If S<=O return O (setter prevents enabled non-elevating spike). Else `O + floor((S-O)*(W-e)/W)`.

Closing ramp only on a day that actually trades, at sec>=open:
- if H=0, no ramp;
- `w=min(U,effectiveClose-open)`;
- with U!=0 and effectiveClose>open, `r=effectiveClose-w`; if `r<=sec<=effectiveClose`, return `O + floor((H-O)*(sec-r)/w)` (runtime H<=O guard returns O);
- otherwise if `effectiveClose<=sec<effectiveClose+V`, return H;
- otherwise zero.

Final calendar model A=max(session floor, closing ramp). The common resolver adds directional premium, applies poke and caps.

Important boundary: with closeAfter=0 and closeBefore>0, peak exists at EXACT bell second due inclusive ramp endpoint, then drops to overnight/Friday-closed tier one second later. This is source behavior, not generic smooth decay. Closing shape is ramp UP then HOLD, not triangular decay.

Configuration validation:
- O,N,X nonzero and <=cap; their minimum becomes configured poke floor and must be >=100;
- W<=21600 (6h), M<=20;
- W>0 requires N*M>O and Sx>O;
- W=0 requires M=0 and Sx=0;
- N*M and Sx MAY exceed cap, so resolver cap must remain;
- H<=cap; H!=0 requires H>=O and at least one of U,V nonzero, both <=21600;
- H=0 requires U=V=0;
- no ordering enforced among O,N,X;
- configuring/reconfiguring an already initialized live pool is permitted.

Do not quote comment fixtures as live calibration. Comments mention NVDA `(1000,800,300,5,4000,7200,2200,1800,0)` and historical `(700,400,300,8,3200,7200,1500,1800,900)`, but this scout did not perform per-pool RPC state reads. Also NVDA has a different older hook address; current shared-hook source cannot automatically be assumed identical to its deployed bytecode.

## Calendar / DST / holidays

Default ET open34200=09:30, close57600=16:00. `dayOfWeek=(epochDay+4)%7`, Sunday0, Friday5, Saturday6.

Classification order is exact and slightly asymmetric:
1. Friday sec>=effectiveClose → CLOSED, even FORCE_OPEN Friday.
2. Unless forceTradingDay, weekends/full-day holiday → CLOSED.
3. open<=sec<close → OPEN.
4. Otherwise OVERNIGHT.

No promotion of trading-day flanks adjacent to holidays beyond explicit Friday post-close rule. Monday pre-open is OVERNIGHT. FORCE_OPEN Saturday/Sunday can trade and then becomes OVERNIGHT after close. Previous date's `_dayFullyClosed` controls opening spike; force-open prior date changes tomorrow's spike choice too.

AUTO DST uses UTC CIVIL DATE, not true transition timestamp. April–October EDT (14400 offset), December–February EST (18000); March changes on second Sunday and November on first Sunday, at UTC midnight of that date. Formula secondSunday=8+(7-DOW(March1))%7; firstSunday=1+(7-DOW(Nov1))%7. This switches several hours before actual 02:00 local boundary. Ordinary switch weekend tiers may mask it, but force-open weekend overlays can expose wrong civil-day classification for an hour near midnight. Exact reproduction includes this quirk; independent improved calendar should not silently claim parity.

Full closure dates baked as MMDD:
- 2026: 0101,0119,0216,0403,0525,0619,0703,0907,1126,1225.
- 2027: 0101,0118,0215,0326,0531,0618,0705,0906,1125,1224.
- 2028: 0117,0221,0414,0529,0619,0704,0904,1123,1225.
- 2029: 0101,0115,0219,0330,0528,0619,0704,0903,1122,1225.
- 2030: 0101,0121,0218,0419,0527,0619,0704,0902,1128,1225.
Outside2026–2030 bakedClosed=false; weekends still apply and storage corrections required for later holidays.

Per-pool storage overlay:
- `setDayOverrides(poolId,year*100+month,uint64 packed)`: two bits/day at `(d-1)*2`; 0 default,1 closed,2 open,3 rejected. Replaces whole month's word. Rejects day32 bits, nonexistent dates, year<1970, invalid month, >10 marked days either direction.
- `setSessionHours`: both anchors must remain within1800s of default (open09:00–10:00, close15:30–16:30), additionally valid same-day ordered nonzero open and 1h–12h length. Anchor bounds practically constrain length5.5h–7.5h. A delayed one-second late opening can nevertheless miss real opening auction; bounds do not guarantee preservation of original bell coverage.
- `setDstMode`: AUTO always accepted. Fixed EST/EDT only if equals current AUTO-derived offset at write time; pin persists across future seasons. No forced ongoing agreement.
- `setEarlyClose`: real date year>=1970; zero clears; nonzero must be after open, <=normal close, leaving >=3h session. Runtime revalidates against possibly changed session anchors and ignores invalid stale overlay.
- HALF-DAYS ARE NOT BAKED. Operator must enter each per pool. Source lists13:00 ET dates 2026-11-27/12-24; 2027-11-26; 2028-07-03/11-24; 2029-07-03/11-23/12-24; 2030-07-03/11-29/12-24. This list is source documentation, not independently corroborated exchange-calendar research.

## Ramp model and keeper availability

`FablesRamp._autonomousFee` simply returns `_flatPips[poolId]`. Config enforces floor<=flat<=cap, minimum100 through common bound setter. The name Ramp does NOT imply on-chain dynamic volatility. Source explicitly says earlier realized-volatility Parkinson tick-range estimator `VolLib` removed: memecoin estimator saturated and external-price adverse selection was invisible without oracle. Current responsiveness is off-chain poke. This historical rationale is a source comment; current executable flat return is verified source.

Meaningful public GitHub searches performed via API:
- https://api.github.com/search/repositories?q=fables+robinhood → two repositories, third-party fable-terminal and imprint-hash/aesop.
- https://api.github.com/search/repositories?q=fables+language%3ASolidity → four unrelated repositories, none official Fables.
- https://api.github.com/search/repositories?q=%22fables.fi%22+in%3Areadme → bstocks-lp-assistant and aesop.
- https://api.github.com/search/repositories?q=%22FablesRWA%22+in%3Areadme →0.
- https://api.github.com/search/repositories?q=%22FablesBaseHook%22+in%3Areadme →0.
- broader fables keeper in:readme produced broad unrelated matches; not evidence of official keeper.

https://github.com/imprint-hash/aesop is public MIT but is LP fee CLAIM/compound automation via KeeperHub, not Fables fee-setting algorithm. README inspected https://raw.githubusercontent.com/imprint-hash/aesop/master/README.md. Do not confuse its gas threshold with dynamic swap-fee policy.

No official fee-setting keeper repository, price feeds, formula, lookback, volatility estimator, update hysteresis or calibration dataset found. Search absence does not prove it is private/nonexistent. Verified hook dictates permissible outputs, not how keeper chooses them. An exact off-chain reproduction remains unavailable.

## Actual keeper execution

https://robin.etherscan.io/tx/0x3efce827593d1108e1c6b7a36f86e71a11b0ac9f6702b77cf66137de76029691
- Success, block68539151, 2026-09-21 05:15:40 UTC.
- Sender `0x014f37FA6f0608C71a7BBC3adf3b587CC24a2163`.
- Target Ramp `0x08E52564Bad99E05a694b4809F397edcA417A080`.
- `pokeFee(bytes32,uint24,uint24,uint40)` selector0x3f740010.
- UBIK/USDG pool `0x4aaa4f57bec2b6e67dac42909c8c4f9a6ddaf02bb63f8dcbbafb35316731d2a7`.
- fee0For1=15000 (1.5%), fee1For0=22500 (2.25%), ttl7200s.
- FeePoked receipt expiry1789974940.
This proves directional keeper overrides actively run, but does not prove the signal that generated them or actual swap fee after runtime clamp.

## Authority, timelocks, powers

All privileged hook setters use OpenZeppelin AccessManaged restricted / `_checkCanCall`; exact roles/delays are external AccessManager STATE, not permanent hook constants. Source comments call fee role FEE_POKER zero delay; clearPoke/pause PAUSER zero delay; calendar CALENDAR_OPS with CONFIG_DELAY; persistent config delayed. These comments are intentions, not enough to certify live role assignments. Pinned state reads, where available, are recorded separately in chain-snapshot.json; do not infer execution delays from manager constants.

Observed Read Contract states:
- Both inspected hooks authority `0xA362D98B33A7bb5B5E2180a05f995A70FB404f30`, absolute max50000 (5%), maxTTL259200=72h, maxDiscount5000bps, MIN_POOL_FEE100.
- RWA calendar constants: maxDayOverrides10, maxDescent21600, maxSpikeMult20, maxSessionShift1800, minEarlyClose10800, minSession3600,maxSession43200.
- Both claim fee ceiling2000bps=20%, maxPause604800=7d, claimFeeWalk32, claimFeeRecipient treasury above.
- ballotGate, distributor, distributorFF observed zero (planned governance not active on these reads).
- AccessManager ADMIN_ROLE0, PUBLIC_ROLE18446744073709551615, expiration604800, minSetback432000 (5d). THESE ARE NOT a blanket5-day transaction timelock! They govern manager machinery; per-role/target execution delay must be separately read.

Read URLs:
https://robin.etherscan.io/readContract?m=normal&a=0x08E52564Bad99E05a694b4809F397edcA417A080&v=0x08E52564Bad99E05a694b4809F397edcA417A080
https://robin.etherscan.io/readContract?m=normal&a=0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080&v=0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080
https://robin.etherscan.io/readContract?m=normal&a=0xA362D98B33A7bb5B5E2180a05f995A70FB404f30&v=0xA362D98B33A7bb5B5E2180a05f995A70FB404f30

## Pinned follow-up and legacy differences

At block 68,544,700, `getTargetFunctionRole` returned role 1 for the shared Ramp/RWA `pokeFee(bytes32,uint24,uint24,uint40)` selector, role 4 for `clearPoke(bytes32)`, and role 0 for each model's configuration selector. `canCall` for the observed keeper returned `(true,0)` for poke and `(false,0)` for clear/config. `getAccess(1,keeper)` returned execution delay zero. This proves that keeper's immediate fee-write permission, not the execution delay of every admin or the completeness of the role roster.

The complete registry snapshot confirms treasury fees of 1,000 bps on all but ETH/USDG, GLD/USDG and SPY/USDG, whose getters returned zero. Older single-pool hooks expose `claimFeeBps()`; newer shared hooks expose `claimFeeBps(bytes32)`. This is direct evidence against treating the dimensions adapter's hardcoded zero protocol revenue as actual treasury policy.

UBIK/USDG's measured state was flat 15,000, floor 3,750, cap 50,000; its override was `(15000,22500,1789974940)` and both `currentFee` calls matched the two override rates. SPCX/USDG's floor tuple was `(2000,500,500,5,3000,1800,2000,1800,1800)`, cap 30,000, floor 500, no active override and current fee 500 each direction. NVDA's current fees were 800/800, cap 8,000 and floor 300. All figures are pips.

Additional verified source was fetched directly from the **NVDA** `0x66622f77B797D506e5376F7798b67ab288966080` and **ETH** `0x06a889870C8f83640D6816319f72e2aA579b6080` explorer code pages. Their base hook differs materially from the newer shared implementation:

- `Poke` contains one `uint24 fee` and one `uint40 expiry`, and the setter is `pokeFee(bytes32,uint24,uint40)`. It is symmetric; no persistent directional-premium method exists.
- A fresh override resolves as `min(cap,max(poke,configuredFloor,floor(rawAutonomous/2)))`. The half-floor uses the **uncapped** autonomous fee, whereas the newer shared implementation uses the capped, direction-premium-inclusive autonomous fee.
- The old `clearPoke` deletes without checking configured membership. The older equity calendar is hook-wide rather than per-pool. ETH remains flat autonomous pricing, not an on-chain volatility estimator.
- These older immutable deployments cannot receive the newer semantics through an ordinary upgrade. The uninspected legacy addresses must not be assumed byte-for-byte identical merely because their getter shapes match.

## Security/docs cautions

Official docs disclose claim fee10% all pools except ETH/USDG, GLD/USDG, SPY/USDG at0%, described as Sept14 state; zero Uniswap protocol fee all pools. These are docs claims unless re-read per pool. Claim fee separate from dynamic LP fee. Treasury cut is applied when range syncs, docs say minimum historical rate spanning backlog prevents retroactive increase.

Official security marketing claims safest class, principal untouchable, immutable, no delta flags. No-delta design confirmed in inspected fee base, but do not convert slogans into a full security audit of ledger. Official tooling claims Olympix, Sherlock AI, pashov AI, fuzz/invariant suites and audited Alphix foundation. Explorer says no contract security audit submitted for inspected addresses. No independent Fables human audit report recovered.

Source retrieval fallback is excellent: https://robinhoodchain.blockscout.com/api/v2/smart-contracts/0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080 returns JSON with source_code/additional sources, and corresponding native URL for0xcA89... returns FablesRWAETH. Full source was recovered from explorer HTML data-cname/data-csource attributes into temporary research storage; it is deliberately not vendored because the custom source is UNLICENSED.

## Remaining gaps for exact reproduction

1. Keeper decision policy and signal inputs unavailable publicly in inspected evidence.
2. The pinned snapshot covers live per-pool fee/config/poke state, but not every stored calendar override or historical configuration transition.
3. NVDA and ETH legacy source differences are documented above; remaining older hook versions were not all source-compared.
4. Selected live selector-role mappings and observed keeper permission are pinned above; complete memberships, administrator execution delays and pending actions were not enumerated.
5. Custom source UNLICENSED: independent implementation of researched mechanics rather than direct source copying.
6. DST boundary approximation and manually-maintained half-days/later holidays mean literal replication and corrected-calendar design are different choices.
