package stables

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// HookAddresses lists every ProtocolFeeHook deployment.
//
// The hook is a UUPS proxy, so the address is stable across upgrades -- and its Uniswap v4
// permissions are mined into the low 14 bits of that address (0x00CC: beforeSwap | afterSwap |
// both return-deltas), so they can never change whatever the implementation behind it does.
// Append new chains here as the stack is deployed to them.
var HookAddresses = []common.Address{
	// Robinhood Chain (chainID 4663), gen-6 stack, deployed 2026-09-17.
	// PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951.
	common.HexToAddress("0xc9932584c5154e4f58313a2e5423522e74e540cc"),
}

var (
	// pipsDenominator is ProtocolFeeHook.PIPS_DENOMINATOR: 1e6 = 100%, the same unit
	// Uniswap quotes PoolKey.fee in.
	pipsDenominator = big.NewInt(1_000_000)

	// maxFeePips is ProtocolFeeHook.MAX_FEE_PIPS, the ceiling the setter itself enforces:
	// 10_000 = 1%. Lowered from 5% on 2026-09-19 precisely so an aggregator integrating
	// this hook has a tight bound on what governance can do to a quote. A read above it
	// means we are talking to something that is not this hook.
	maxFeePips = big.NewInt(10_000)
)

// What the hook adds to a swap, over an otherwise identical pool with no hook attached.
// Measured by running the same swap against both, in the protocol's own
// test/markets/HookGasOverhead.t.sol, which asserts these bands so they cannot drift here
// unnoticed:
//
//	exact-in, first swap of the block   79,857
//	exact-in, later in the same block   20,156
//	exact-out, later in the same block  20,242
//
// Two costs, not one. The oracle write happens in beforeSwap on every swap of a REGISTERED
// pool -- either direction, and whatever the rate -- but only once per block, because
// PoolObservations.write is a no-op when an observation for the block already exists. The skim
// is a separate ERC-6909 mint in afterSwap, charged on the unspecified currency; since
// 2026-09-19 that is both directions, so the two figures above are within ~100 gas of each
// other rather than differing by a callback.
const (
	gasObservation int64 = 60_000
	gasAccrue      int64 = 20_000
)
