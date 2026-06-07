# Security Policy

MuteMaster is an open-source hobby project maintained on a best-effort basis.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under the repo's **Security** tab), or contact the maintainer directly.
You'll get a response as soon as reasonably possible.

## Important: this project installs a privileged helper and an audio driver

MuteMaster installs two pieces of system software, so please understand what you're running before
installing — especially a build you didn't compile yourself:

- **A privileged helper** (`MuteMasterHelper`) registered via `SMAppService`. It runs as **root** and
  exists solely to copy the audio driver into `/Library/Audio/Plug-Ins/HAL` and restart `coreaudiod`.
  Its source is in [`MuteMasterHelper/`](MuteMasterHelper/).
- **A Core Audio driver** (`MuteMasterDriver.driver`) loaded by the system `coreaudiod` process. Its
  source is in [`MuteMasterDriver/`](MuteMasterDriver/).

## Known hardening work (before treating a build as production-grade)

The local-development build prioritizes being easy to build and inspect. If you distribute or rely on
this in a sensitive setting, address the following first:

- **XPC client validation.** The helper currently accepts XPC connections without verifying the
  caller's code signature (`shouldAcceptNewConnection` in
  [`MuteMasterHelper/main.swift`](MuteMasterHelper/main.swift) has a TODO). A production build must
  validate the connecting client's audit token against the app's designated code requirement so only
  the genuine app can drive the root helper.
- **Signing & notarization.** Dev builds are **ad-hoc signed**. Distributable builds should use a
  Developer ID identity, the hardened runtime, and notarization.

## Supported versions

This project does not maintain long-term release branches; fixes land on the default branch. Use the
latest commit.
