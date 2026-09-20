# Deployment Summary - Robinhood Chain Testnet

> **⚠ This is the TESTNET deployment record (chain 46630).**
> The mainnet deployment (chain 4663) is a different set of addresses entirely — see
> **Our deployment** in [README.md](README.md). Nothing on this page applies to mainnet.
>
> **⚠ This record predates the 2026-09-08 security review.** Everything below was deployed from
> source that lacks the per-consumer yield-adapter accounting, the admin gate on
> `VaultTreasury.redeem`/`redeemAll`, the owner gate on `LiquiditySweeper`, and the memecoin
> graduation-price, reentrancy and pool-squat fixes. It is a testnet with mock money, so nothing
> here is at risk — but **do not treat these addresses as a reference for current behavior**, and
> redeploy before using this environment to validate anything security-related. `DeployTestnet.s.sol`
> itself is current: it now passes the deployer as `LiquiditySweeper`'s owner, so a fresh run
> produces the gated build even though the address recorded below is the ungated one.
>
> The current integration deployment is on Base Sepolia and is recorded separately in
> [`deployments/asset-markets-base-sepolia.json`](deployments/asset-markets-base-sepolia.json).


## Deployment Information

**Date:** 2026-09-07  
**Network:** Robinhood Chain Testnet (Chain ID: 46630)  
**Deployer:** 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9

## Deployed Contracts

### Core Infrastructure

| Contract | Address | Description |
|----------|---------|-------------|
| **MockUSDC** | `0xecF46dC819Ef7523b842852B1026a5622889FB11` | Test stablecoin (6 decimals) |
| **MockYieldSource** | `0x9050dF2f672dEb3Cf4900349005ecd11b2497654` | Mock yield source for testing |
| **TimelockController** | `0x6E76Fadb297711Cf185Eba6e755B00985718B895` | Upgrade authority (1 hour delay) |

### Branded Vault System

| Contract | Address | Description |
|----------|---------|-------------|
| **BrandedVault Implementation** | `0xd20c4D8D9AEDEA4BA88A5aebcf8D425A22f3C426` | Vault logic (upgradeable) |
| **UpgradeableBeacon** | `0x7044E3290213F463879BBe929F22BA2Eb8089762` | Beacon for vault upgrades |
| **BrandedVaultFactory Implementation** | `0x19c71817265fD79A5113e9fA0E599E890192b7fb` | Factory logic (upgradeable) |
| **BrandedVaultFactory Proxy** | `0x643cE5f935aA536bf97B148734cE7aa80BEb51B4` | Factory proxy (UUPS) |
| **BrandedVault (stUSD)** | `0x2C0F637838a91280D5b4E044A7324b4521785829` | Flagship vault instance |

### Memecoin Launchpad

| Contract | Address | Description |
|----------|---------|-------------|
| **MockUniswapV3Factory** | `0xdd43F23b4383287A87E1f42934B6F81E2E9F6bee` | Mock Uniswap V3 factory |
| **MockPositionManager** | `0x1026D55461a100f7397e381087F67723E9A46e8c` | Mock LP position manager |
| **MemecoinFactory** | `0x71300c2D29e5d218f17c16F377D3e8C1469405db` | Memecoin creation factory |
| **LiquiditySweeper** | `0xF35c06972Ea8c3A06b889A8da4Ae435960248874` | USDG sweeping contract |

### Test Tokens

| Contract | Address | Description |
|----------|---------|-------------|
| **Test Sweep Coin (TSC)** | `0xd576712ba7e273a14391850df417eea31b973a8a` | Test memecoin |

## Test Results

### ✅ Deployment Successful

All contracts deployed successfully in a single transaction:
- Total gas used: ~16M gas
- Estimated cost: ~0.00032 ETH (testnet ETH)

### ✅ Memecoin Creation Test

Successfully created "Test Sweep Coin" (TSC):
- Token address: `0xd576712ba7e273a14391850df417eea31b973a8a`
- Total supply: 1B tokens
- Quote token: MockUSDC

### ✅ Buy Test

Successfully bought TSC tokens:
- Spent: 100 USDC
- Received: ~283.67M TSC tokens
- Fees distributed correctly (50% creator, 25% brand, 25% protocol)
- Bonding curve working as expected

## Contract Verification

All contracts can be verified on the Robinhood Chain explorer:
- Explorer URL: https://robinhoodchain.blockscout.com/
- Add `ROBINHOOD_EXPLORER_API_KEY` to `.env` for automatic verification

## Testing the Full Flow

### 1. Create a Branded Vault

```bash
cast send $TESTNET_BRANDED_VAULT_FACTORY \
  "createVault(string,string,uint256)(address)" \
  "My Brand USD" "mbUSD" 1000 \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 2. Deposit to Vault

```bash
# Approve USDC
cast send $TESTNET_MOCK_USDC \
  "approve(address,uint256)" \
  $TESTNET_BRANDED_VAULT 1000000000 \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY

# Deposit
cast send $TESTNET_BRANDED_VAULT \
  "deposit(uint256,address)(uint256)" \
  100000000 $DEPLOYER \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 3. Deploy to Yield Source

```bash
cast send $TESTNET_BRANDED_VAULT \
  "deployIdle()" \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 4. Create a Memecoin

```bash
cast send $TESTNET_MEMECOIN_FACTORY \
  "createToken(string,string,address,address)(address)" \
  "My Meme" "MEME" $TESTNET_MOCK_USDC $DEPLOYER \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 5. Buy Memecoin

```bash
# Approve USDC
cast send $TESTNET_MOCK_USDC \
  "approve(address,uint256)" \
  $MEMECOIN_ADDRESS 1000000000 \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY

# Buy
cast send $MEMECOIN_ADDRESS \
  "buy(uint256,uint256)(uint256)" \
  100000000 0 \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 6. Sweep and Redeploy (when ready)

```bash
cast send $TESTNET_LIQUIDITY_SWEEPER \
  "sweepAndRedeploy(uint256,address,address)(uint256,uint256)" \
  $LP_TOKEN_ID $TESTNET_BRANDED_VAULT $TREASURY \
  --rpc-url $TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

## Environment Variables

All contract addresses are stored in `.env`:

```env
TESTNET_MOCK_USDC=0xecF46dC819Ef7523b842852B1026a5622889FB11
TESTNET_MOCK_YIELD_SOURCE=0x9050dF2f672dEb3Cf4900349005ecd11b2497654
TESTNET_TIMELOCK=0x6E76Fadb297711Cf185Eba6e755B00985718B895
TESTNET_BRANDED_VAULT_IMPL=0xd20c4D8D9AEDEA4BA88A5aebcf8D425A22f3C426
TESTNET_UPGRADEABLE_BEACON=0x7044E3290213F463879BBe929F22BA2Eb8089762
TESTNET_BRANDED_VAULT_FACTORY_IMPL=0x19c71817265fD79A5113e9fA0E599E890192b7fb
TESTNET_BRANDED_VAULT_FACTORY=0x643cE5f935aA536bf97B148734cE7aa80BEb51B4
TESTNET_BRANDED_VAULT=0x2C0F637838a91280D5b4E044A7324b4521785829
TESTNET_MOCK_UNISWAP_FACTORY=0xdd43F23b4383287A87E1f42934B6F81E2E9F6bee
TESTNET_MOCK_POSITION_MANAGER=0x1026D55461a100f7397e381087F67723E9A46e8c
TESTNET_MEMECOIN_FACTORY=0x71300c2D29e5d218f17c16F377D3e8C1469405db
TESTNET_LIQUIDITY_SWEEPER=0xF35c06972Ea8c3A06b889A8da4Ae435960248874
TESTNET_MEMECOIN_TSC=0xd576712ba7e273a14391850df417eea31b973a8a
```

## Notes

### Mock Contracts

The testnet deployment uses **mock contracts** for:
- **MockUSDC**: Test stablecoin (not real USDG)
- **MockYieldSource**: Simulates yield accrual
- **MockUniswapV3Factory/PositionManager**: Simulates Uniswap V3

These mocks allow testing the full flow without depending on external protocols.

### Upgradeability

All core contracts are **upgradeable**:
- **BrandedVault**: Behind UpgradeableBeacon
- **BrandedVaultFactory**: UUPS proxy pattern
- **TimelockController**: 1-hour delay for upgrades

To upgrade:
1. Deploy new implementation
2. Call `upgradeTo()` through timelock
3. Wait 1 hour
4. Execute upgrade

### Next Steps for Mainnet

For mainnet deployment:
1. Replace mock contracts with real ones:
   - MockUSDC → Real USDG
   - MockYieldSource → MorphoBlueYieldSource
   - MockUniswapV3 → Real Uniswap V3
2. Increase timelock delay (24-48 hours)
3. Deploy to mainnet using `DeployMainnet.s.sol`
4. Verify contracts on explorer

## Summary

✅ **All systems operational on testnet**

The complete branded stablecoin + memecoin launchpad system is deployed and tested:
- Branded vaults with yield generation
- Memecoin creation with bonding curves
- Liquidity sweeping with automatic redeployment
- Full upgradeability and governance

Ready for mainnet deployment when real protocols are available!
