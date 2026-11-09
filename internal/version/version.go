package version

import (
	"fmt"
	"os"
	"strings"
)

// Version is the release version (overridable via -ldflags at build time).
var Version = "1.1.1"

// ContractVersion is the upstream @remnawave/node version reported to Panel as nodeVersion.
// Default must stay in sync with contract.version and contract-sync CI.
// Overridable via -ldflags at build time.
var ContractVersion = "2.8.0"

// ReleaseRepo is the GitHub repository that hosts release assets, deploy scripts and the
// self-hosted dist/ tarballs. This is the cerezoelkin404 fork on purpose: nothing in the
// node lifecycle may resolve against the upstream ike-sh repository any more.
// Keep in sync with the REPO defaults in scripts/*.sh and deploy/*.
const ReleaseRepo = "cerezoelkin404/remnawave-node-lite-go"

// releaseRepo keeps the unexported historical name used by the URL builders below.
const releaseRepo = ReleaseRepo

// ReportedNodeVersion returns the nodeVersion sent to Panel.
// Priority: NODE_CONTRACT_VERSION env > ContractVersion (build-time default).
// Mirrors upstream reading package.json version at bootstrap.
func ReportedNodeVersion() string {
	if v := strings.TrimSpace(os.Getenv("NODE_CONTRACT_VERSION")); v != "" {
		return v
	}
	return ContractVersion
}

func String() string {
	return fmt.Sprintf("remnawave-node-lite-go %s (contract %s)", Version, ReportedNodeVersion())
}

func ReleaseAssetURL(tag, arch string) string {
	return fmt.Sprintf(
		"https://github.com/%s/releases/download/%s/remnanode-lite_linux_%s.tar.gz",
		releaseRepo,
		tag,
		arch,
	)
}

// DistAssetURL returns the tarball committed under dist/ in this repository, served by
// raw.githubusercontent.com. It is the fallback used when the fork has no GitHub Release
// asset (e.g. Actions disabled on a fork), so installs never fall back to ike-sh.
func DistAssetURL(tag, arch string) string {
	return fmt.Sprintf(
		"https://raw.githubusercontent.com/%s/%s/dist/remnanode-lite_linux_%s.tar.gz",
		releaseRepo,
		tag,
		arch,
	)
}

func InstallScriptURL(tag, script string) string {
	return fmt.Sprintf(
		"https://raw.githubusercontent.com/%s/%s/scripts/%s",
		releaseRepo,
		tag,
		script,
	)
}
