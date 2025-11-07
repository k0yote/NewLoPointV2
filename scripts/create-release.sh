#!/bin/bash

# NewLo JPYC Bridge - Release Creation Script
# Usage: ./scripts/create-release.sh <version>
# Example: ./scripts/create-release.sh 0.1.0

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_error() {
    echo -e "${RED}❌ Error: $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Check if version provided
if [ -z "$1" ]; then
    print_error "Version number required"
    echo "Usage: $0 <version>"
    echo "Example: $0 0.1.0"
    exit 1
fi

VERSION=$1
TAG="v${VERSION}"

print_info "Creating release ${TAG}"
echo ""

# Validate version format
if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+(\.[0-9]+)?)?$ ]]; then
    print_error "Invalid version format: ${VERSION}"
    echo "Expected format: X.Y.Z or X.Y.Z-beta.N"
    exit 1
fi

# Check if on main branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    print_warning "Not on main branch (current: ${CURRENT_BRANCH})"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    print_error "Uncommitted changes detected"
    echo "Please commit or stash your changes first"
    exit 1
fi

# Pull latest changes
print_info "Pulling latest changes..."
git pull origin main

# Run tests
print_info "Running tests..."
if ! forge test; then
    print_error "Tests failed"
    exit 1
fi
print_success "All tests passed"

# Build contracts
print_info "Building contracts..."
if ! forge build; then
    print_error "Build failed"
    exit 1
fi
print_success "Build successful"

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    print_error "Tag ${TAG} already exists"
    exit 1
fi

# Update CHANGELOG.md
print_info "Please update CHANGELOG.md with release notes"
print_info "Press Enter when ready to continue..."
read

# Show what will be included in the release
echo ""
print_info "Changes since last release:"
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
    git log ${LAST_TAG}..HEAD --oneline --decorate
else
    git log --oneline --decorate
fi
echo ""

# Confirm release
read -p "Create release ${TAG}? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Release cancelled"
    exit 0
fi

# Create git tag
print_info "Creating git tag ${TAG}..."
git tag -a "$TAG" -m "Release ${TAG}"
print_success "Tag created"

# Push tag
print_info "Pushing tag to remote..."
git push origin "$TAG"
print_success "Tag pushed"

# Generate release notes
print_info "Generating release notes..."

# Determine if pre-release
PRE_RELEASE=""
if [[ $VERSION =~ -(alpha|beta|rc) ]]; then
    PRE_RELEASE="--prerelease"
    print_info "This will be marked as a pre-release"
fi

# Create GitHub release
print_info "Creating GitHub release..."

# Read CHANGELOG for this version
CHANGELOG_SECTION=$(awk "/## \[${VERSION}\]/,/## \[/" CHANGELOG.md | sed '1d;$d')

if [ -z "$CHANGELOG_SECTION" ]; then
    print_warning "No changelog found for ${VERSION}, using git log"
    if [ -n "$LAST_TAG" ]; then
        CHANGELOG_SECTION=$(git log ${LAST_TAG}..HEAD --pretty=format:"* %s (%h)")
    else
        CHANGELOG_SECTION=$(git log --pretty=format:"* %s (%h)")
    fi
fi

# Create release
gh release create "$TAG" \
    --title "Release ${TAG}" \
    --notes "${CHANGELOG_SECTION}

## Deployment

See [deployment documentation](./README.md#deployment) for instructions.

## Testing

All tests passing ✅

\`\`\`bash
forge test
\`\`\`

**Full Changelog**: https://github.com/$(gh repo view --json nameWithOwner --jq '.nameWithOwner')/compare/${LAST_TAG}...${TAG}

🤖 Generated with Release Script" \
    $PRE_RELEASE

print_success "GitHub release created: https://github.com/$(gh repo view --json nameWithOwner --jq '.nameWithOwner')/releases/tag/${TAG}"

echo ""
print_success "Release ${TAG} created successfully!"
echo ""
print_info "Next steps:"
echo "  1. Verify the release on GitHub"
echo "  2. Update documentation if needed"
echo "  3. Announce the release"
echo "  4. Deploy to testnet/mainnet as appropriate"
