# Release Process

This document describes the release process for the NewLo JPYC Bridge project.

## Versioning

We follow [Semantic Versioning](https://semver.org/) (SemVer):

```
MAJOR.MINOR.PATCH[-PRERELEASE]

Examples:
- 0.1.0 - Initial beta release
- 1.0.0 - First stable release
- 1.1.0 - New features (backward compatible)
- 1.1.1 - Bug fixes
- 2.0.0 - Breaking changes
- 1.2.0-beta.1 - Pre-release version
```

### Version Guidelines

**MAJOR** (X.0.0) - Increment when:
- Breaking changes to smart contract interfaces
- Incompatible protocol changes
- Major architecture changes requiring migration

**MINOR** (0.X.0) - Increment when:
- New features added (backward compatible)
- New contracts added
- Significant improvements

**PATCH** (0.0.X) - Increment when:
- Bug fixes
- Security patches
- Documentation updates
- Performance improvements

**PRERELEASE** (0.0.0-X) - Use for:
- `alpha` - Early testing, unstable
- `beta` - Feature complete, testing phase
- `rc.N` - Release candidate, final testing

## Release Types

### 1. Development Releases (0.x.x)

For initial development and testing:
- Use `0.x.x` versions
- Mark as pre-release on GitHub
- Deploy to testnets only

### 2. Stable Releases (1.x.x+)

For production use:
- Version `1.0.0` and above
- Full security audit required
- Deployment to mainnet

## Release Workflow

### Automated Release (Recommended)

```bash
# 1. Make sure you're on main branch with latest changes
git checkout main
git pull origin main

# 2. Update CHANGELOG.md with release notes
# Edit CHANGELOG.md and add your changes under [Unreleased]

# 3. Run the release script
./scripts/create-release.sh 0.1.0

# The script will:
# - Validate version format
# - Run tests
# - Build contracts
# - Create git tag
# - Push to GitHub
# - Create GitHub release
```

### Manual Release

If you prefer to create releases manually:

```bash
# 1. Update CHANGELOG.md
# Move [Unreleased] changes to new version section

# 2. Commit changes
git add CHANGELOG.md
git commit -m "chore: prepare release v0.1.0"

# 3. Create tag
git tag -a v0.1.0 -m "Release v0.1.0"

# 4. Push changes and tag
git push origin main
git push origin v0.1.0

# 5. Create GitHub release
gh release create v0.1.0 \
  --title "Release v0.1.0" \
  --notes-file RELEASE_NOTES_v0.1.0.md
```

## Pre-Release Checklist

Before creating a release, ensure:

### Code Quality
- [ ] All tests passing (`forge test`)
- [ ] No compiler warnings (`forge build`)
- [ ] Code formatted (`forge fmt`)
- [ ] All PRs merged to main

### Documentation
- [ ] CHANGELOG.md updated
- [ ] README.md reflects latest changes
- [ ] Architecture diagrams up to date
- [ ] Deployment guides current

### Security
- [ ] Slither analysis completed
- [ ] No high/critical vulnerabilities
- [ ] Security audit (for mainnet releases)
- [ ] Access control verified

### Testing
- [ ] Unit tests passing
- [ ] Integration tests passing
- [ ] Testnet deployment verified (for mainnet releases)

## Post-Release Checklist

After creating a release:

### Verification
- [ ] GitHub release created successfully
- [ ] Tag pushed to repository
- [ ] Release notes accurate and complete
- [ ] Artifacts attached (if any)

### Communication
- [ ] Update project documentation
- [ ] Notify team/community
- [ ] Update deployment instructions
- [ ] Announce on relevant channels

### Deployment
- [ ] Deploy to testnet (for testing releases)
- [ ] Verify contracts on block explorer
- [ ] Test end-to-end functionality
- [ ] Monitor for issues

## Release Notes Template

When creating `RELEASE_NOTES_vX.Y.Z.md`:

```markdown
# Release vX.Y.Z - [Release Name]

## Overview
[Brief description of this release]

## Features
### Added
- Feature 1
- Feature 2

### Changed
- Change 1
- Change 2

### Fixed
- Bug fix 1
- Bug fix 2

## Smart Contracts
[List of contracts added/changed]

## Testing
- X tests passing
- [Notable test improvements]

## Documentation
- [New/updated docs]

## Important Notes
- [Breaking changes]
- [Migration guides]
- [Known issues]

## Links
- Repository: [URL]
- Full Changelog: [URL]
```

## GitHub Actions

Our repository uses GitHub Actions to automate releases:

### Workflow: `.github/workflows/release.yml`

**Triggers**: When a tag matching `v*.*.*` is pushed

**Actions**:
1. Checkout code
2. Install Foundry
3. Run tests
4. Build contracts
5. Generate changelog
6. Create GitHub release
7. Upload build artifacts

**To trigger**:
```bash
git tag v0.1.0
git push origin v0.1.0
```

## Version Management

### Current Version

Check current version:
```bash
git describe --tags --abbrev=0
```

### Next Version

Determine next version based on changes:
- Breaking changes → Increment MAJOR
- New features → Increment MINOR
- Bug fixes → Increment PATCH

### Pre-release Versions

For testing before stable release:
```bash
# Beta releases
git tag v1.0.0-beta.1
git tag v1.0.0-beta.2

# Release candidates
git tag v1.0.0-rc.1
git tag v1.0.0-rc.2

# Stable release
git tag v1.0.0
```

## Hotfix Process

For urgent fixes to production releases:

```bash
# 1. Create hotfix branch from release tag
git checkout -b hotfix/v1.0.1 v1.0.0

# 2. Make fixes and commit
git commit -m "fix: critical bug"

# 3. Create new patch version
git tag v1.0.1

# 4. Merge back to main
git checkout main
git merge hotfix/v1.0.1

# 5. Push changes and tag
git push origin main
git push origin v1.0.1

# 6. Create hotfix release
gh release create v1.0.1 \
  --title "Hotfix v1.0.1" \
  --notes "Critical bug fixes"
```

## Release Artifacts

Each release should include:

### Source Code
- Automatically attached by GitHub
- `Source code (zip)` and `Source code (tar.gz)`

### Build Artifacts (Optional)
- Compiled contracts (`out/`)
- Deployment scripts
- ABIs

### Documentation
- CHANGELOG.md
- Release notes
- Deployment guides

## Troubleshooting

### Tag Already Exists

```bash
# Delete local tag
git tag -d v0.1.0

# Delete remote tag
git push origin :refs/tags/v0.1.0

# Recreate tag
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

### Failed Release

```bash
# Delete GitHub release
gh release delete v0.1.0

# Delete tag
git tag -d v0.1.0
git push origin :refs/tags/v0.1.0

# Fix issues and retry
```

### Update Existing Release

```bash
# Edit release notes
gh release edit v0.1.0 --notes "Updated notes"

# Mark as pre-release
gh release edit v0.1.0 --prerelease

# Mark as latest
gh release edit v0.1.0 --latest
```

## Best Practices

1. **Test thoroughly** before releasing
2. **Update documentation** before tagging
3. **Use meaningful release notes** - explain what changed and why
4. **Follow SemVer strictly** - helps users understand impact
5. **Tag from main branch** - ensure stability
6. **Announce releases** - keep community informed
7. **Monitor post-release** - watch for issues

## Resources

- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [Foundry Book](https://book.getfoundry.sh/)

---

For questions or issues with the release process, please open an issue on GitHub.
