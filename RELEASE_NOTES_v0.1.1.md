# Release v0.1.1 - Bug Fix Release

## 🔧 Overview

This is a patch release that fixes the GitHub Actions automated release workflow.

## 🐛 Bug Fixes

### GitHub Actions Workflow

**PR #4 - Upload Artifact Deprecation Fix**
- **Fixed**: Updated `actions/upload-artifact` from v3 to v4
  - Resolves deprecation warning in release workflow
  - Ensures automated releases continue to function when version tags are pushed
  - No impact on contract functionality

**PR #6 - Git Submodules Initialization**
- **Fixed**: Added `submodules: recursive` to checkout step
  - Fixes missing `solidity-bytes-utils` dependency for LayerZero-v2
  - Resolves build error: `BytesLib.sol` not found during CI builds
  - Ensures all nested dependencies are properly initialized in GitHub Actions

## 📝 Changes

### Infrastructure
- `.github/workflows/release.yml`
  - Updated `actions/upload-artifact` from v3 to v4
  - Added `submodules: recursive` to `actions/checkout@v4`

## ✅ Testing

- All 35 tests passing
- No changes to smart contract code
- Release workflow validated

## 🔗 Links

- **Repository**: https://github.com/k0yote/NewLoPointV2
- **Pull Requests**:
  - [#4](https://github.com/k0yote/NewLoPointV2/pull/4) - Upload artifact fix
  - [#6](https://github.com/k0yote/NewLoPointV2/pull/6) - Git submodules fix
- **Full Changelog**: https://github.com/k0yote/NewLoPointV2/compare/v0.1.0...v0.1.1

## ⚠️ Important Notes

### No Contract Changes
- This release contains **no smart contract changes**
- Only affects GitHub Actions automation infrastructure
- Existing v0.1.0 deployments are unaffected and do not need updates

### Deployment Status
- ⚠️ Beta release - recommended for testnet only
- ⚠️ Mainnet deployment requires professional security audit (same as v0.1.0)

## 📦 What's Next

- Continue testing on testnets
- Gather community feedback
- Prepare for professional security audit
- Plan for v0.2.0 with new features

---

**Full Changelog**: https://github.com/k0yote/NewLoPointV2/compare/v0.1.0...v0.1.1
