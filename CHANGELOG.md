# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-11-07

### Added

#### Core Bridge Functionality
- Cross-chain NLP to JPYC exchange with automatic failure recovery
- Lock/Unlock/Burn pattern for secure token handling
- Bidirectional messaging for atomicity guarantees
- Support for both LayerZero V2 and Chainlink CCIP protocols

#### Smart Contracts
- `NLPMinterBurner.sol` - Authorized contract for burning NLP tokens on Soneium
- `NLPOAppAdapter.sol` - LayerZero OApp adapter with Lock/Unlock/Burn logic
- `NLPCCIPAdapter.sol` - Chainlink CCIP adapter with Lock/Unlock/Burn logic
- `JPYCVault.sol` - JPYC liquidity pool with role-based access control
- `NLPOAppJPYCReceiver.sol` - LayerZero receiver that handles JPYC exchange (V1)
- `NLPCCIPJPYCReceiver.sol` - CCIP receiver that handles JPYC exchange (V1)

#### JPYC Management (PR #2)
- `JPYCVault.depositWithPermit()` - EIP-2612 gasless approval for single-transaction deposits
  - 40% gas reduction (111k → 66k gas)
  - Better UX with off-chain signature
  - Comprehensive test suite (9 tests)
- `NLPOAppJPYCReceiverV2.sol` - Self-custody LayerZero receiver without JPYCVault dependency
- `NLPCCIPJPYCReceiverV2.sol` - Self-custody CCIP receiver without JPYCVault dependency
  - Simpler architecture
  - No EXCHANGE_ROLE management needed
  - Direct JPYC transfers with detailed error reporting
  - Comprehensive test suite (10 tests)

#### Testing
- Integration tests for full cross-chain flow (3 tests)
- Unit tests for adapters (13 tests)
- Unit tests for JPYCVault depositWithPermit (9 tests)
- Unit tests for ReceiverV2 (10 tests)
- **Total: 35 tests, all passing** ✅

#### Documentation
- `ARCHITECTURE.md` - Detailed system architecture with sequence diagrams
- `DEPOSIT_GUIDE.md` - Comprehensive guide for JPYC deposit operations (3 methods)
- `RECEIVER_V2_GUIDE.md` - V2 receiver deployment and operation guide
- `SECURITY_AUDIT.md` - Security audit report with Slither analysis
- `CLAUDE.md` - Project overview and development commands

#### Development Tools
- Foundry deployment scripts for LayerZero and CCIP
- `script/DepositWithPermit.s.sol` - Permit-based deposit script
- TypeScript examples (`examples/deposit-jpyc-vault.ts`)
- Shell script examples (`examples/deposit-jpyc-vault.sh`)

### Changed
- Updated `foundry.toml` to enable `via_ir` for stack depth resolution

### Fixed
- N/A (initial release)

### Security
- Slither static analysis completed
- All medium-severity issues addressed
- No high or critical vulnerabilities found
- Professional third-party security audit recommended before mainnet deployment

## Release Notes

### v0.1.0 - Initial Beta Release

This is the first beta release of the NewLo JPYC Cross-Chain Bridge. The system enables users to:
- Lock NLP tokens on Soneium
- Receive JPYC tokens on Polygon
- Automatic failure recovery if JPYC transfer fails

**Key Features:**
- Dual protocol support (LayerZero V2 & Chainlink CCIP)
- 40% gas savings with depositWithPermit
- Simplified V2 receivers without vault dependency
- Comprehensive test coverage (35 tests)
- Complete documentation and examples

**Deployment Status:**
- ⚠️ Beta release - recommended for testnet only
- ⚠️ Mainnet deployment requires professional security audit

**Links:**
- Full Release Notes: [RELEASE_NOTES_v0.1.0.md](./RELEASE_NOTES_v0.1.0.md)
- Repository: https://github.com/k0yote/NewLoPointV2
- Pull Requests: [#1](https://github.com/k0yote/NewLoPointV2/pull/1), [#2](https://github.com/k0yote/NewLoPointV2/pull/2)

---

[Unreleased]: https://github.com/k0yote/NewLoPointV2/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/k0yote/NewLoPointV2/releases/tag/v0.1.0
