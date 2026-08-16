# Security policy

## Supported versions

Security fixes are applied to the current `bet` branch and latest release. The
`bluff` branch may contain unreleased integration work.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability, unsafe command
construction, credential exposure, or remote-handling flaw. Use the
repository's **Security** tab and select **Report a vulnerability**.

Include the affected commit or release, a minimal reproduction, expected
impact, and any suggested mitigation. You should receive an initial response
within seven days.

## GitHub credential boundary

GitPanel accepts bearer tokens only through GitHub CLI's credential handling or
the configured `github.token_provider`. It does not persist tokens, render them,
include them in notifications, or place them in process arguments. Raw GitHub
App private keys and OAuth refresh tokens are intentionally outside the plugin's
trust boundary; keep them in an external helper or secret vault that returns a
short-lived access token.

Reports involving token redaction, provider callbacks, remote parsing, curl
standard input, subprocess environments, or GitHub Enterprise URL construction
should be submitted privately under this policy.

Custom REST bases must use HTTPS. The curl transport ignores user-level curl
configuration and does not follow redirects while an authorization header may
be present.
