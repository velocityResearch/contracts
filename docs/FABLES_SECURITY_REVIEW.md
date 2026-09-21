# Stored dynamic LP fee security notes

Scope: the simplified implementation in `feature/keeper-lp-fees`, based on `main` at `57db3d0` with the undeployed on-chain skim policy removed. No deployment or external audit certification is implied. Current execution evidence is recorded separately in [FABLES_VERIFICATION.md](FABLES_VERIFICATION.md).

## Small on-chain authority surface

`ProtocolFeeHook` keeps its existing swap skim, observation ring and upgrade authority. The owner appoints or revokes one fee-only keeper. The owner or that keeper may set a registered dynamic pool's native Uniswap LP fee within 100–50,000 pips (0.01–5%). The key must name this hook and the exact dynamic flag. Static pools are not mutable through this setter.

The keeper does not gain custody, withdrawal, recipient, registrar, protocol-skim, ownership or upgrade powers. Initialization sets 5,000 pips during dynamic registration. Both trade directions use the stored fee, and the hook returns no per-swap LP-fee override. Fee and keeper changes emit events.

The initial policy/calendar experiment was never deployed. Its contracts, per-swap external call, policy binding, delayed policy installation, gas-based fallback and override expiry are removed. They are not hidden behind a compatibility interface. Only the keeper address is appended to the pre-experiment hook storage layout.

## Economic power is still real

A compromised keeper can choose any rate within the hard bounds, immediately. Off-chain pool caps, calendars and reference checks constrain the shipped program, not a malicious signer calling the contract directly. A low rate can undercompensate LPs for adverse selection; a high rate can suppress volume or worsen accepted fills. These are not bounded by a promise of principal safety or profitability.

Revocation stops future writes but does not restore the previous rate. There is no automatic expiry, autonomous on-chain schedule or fallback. If the process stops or a reference fails, the last fee persists. Operators must monitor failed/missed updates and retain a separate owner able to correct the rate and revoke the keeper. Existing UUPS ownership remains the stronger authority and can replace the implementation.

## Off-chain and quoting boundaries

- The keeper validates market identity, exact pool key, reserve/token normalization, hook ownership/keeper authority, chain and reference identity before writing. Reference validation is not proof of economic independence or manipulation resistance.
- Reads are pinned to a block; execution performs a fresh read/plan, simulates the update and checks its receipt/event/stored fee. The cast signing chain is explicit. Same-chain state can still change before inclusion.
- No reference is a deliberate baseline-only mode. A configured reference that fails safety checks is an error and must not become a baseline write.
- Calendar rules and explicit holidays/early closes are operator inputs. Future exchange closures and timezone-law changes require maintenance.
- Native slot0 LP-fee reads are authoritative for this design. Consumers preserve `0x800000` as pool identity and must not interpret it as a fee. Unreadable dynamic observations are unavailable, not zero or a cached directional policy rate.
- Quote freshness and minimum-output/maximum-input protections remain necessary. An authorized update between quoting and settlement can cause a protected trade to revert.

## Historical review record

The [archived source reviews](research/fables/security-review.json) describe the earlier, more complex policy implementation. They are retained as provenance, not represented as independent audits of this simplified revision.

That review found **FABLES-OFFCHAIN-001**: cast signing originally omitted the checked chain ID. The keeper was changed to pass an explicit `--chain`; that protection must survive this cutover. The historical unlocked-Anvil smoke rejected a mismatched signing chain before broadcast, but did not exercise encrypted-keystore signing or a switching two-network RPC proxy.

Production activation, credential creation, upstream aggregator acceptance and profitable calibration remain outside this change.
