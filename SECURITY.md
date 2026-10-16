# Security Policy

## Reporting a vulnerability

Do not report vulnerabilities through public Issues, Discussions, or pull requests.

Preferred channel: [GitHub private vulnerability reporting](https://github.com/eliasthecactus/mountli/security/advisories/new). If GitHub private reporting is unavailable, email [mail@benavo.ch](mailto:mail@benavo.ch) with the subject `Mountli security report`.

Include:

- affected Mountli version, Apple platform/version, and storage backend;
- a clear impact statement and minimal reproduction;
- whether exploitation risks data disclosure, unauthorized mutation, credential exposure, sandbox escape, or update compromise;
- known mitigations and your preferred credit or anonymity.

Never include live credentials, private keys, access tokens, customer data, unredacted file names/paths, or destructive exploit payloads. Use disposable fixtures and redact diagnostics before attaching them.

## Response and coordinated disclosure

Reports are triaged privately through a draft GitHub Security Advisory. We will confirm receipt when practical, validate impact, coordinate a fix and disclosure timing with the reporter, and publish affected/patched versions and mitigations. As a solo-maintained free project, Mountli cannot promise acknowledgment, assessment, remediation, support, or disclosure deadlines.

Please avoid public disclosure until a fix or practical mitigation is available and users have had a reasonable update window. Urgent active exploitation may require accelerated disclosure. Reporter credit is included unless anonymity is requested. A CVE is requested when appropriate.

## Supported versions

Security fixes are published for the current release. After 1.0, Mountli supports the current and previous major Apple operating-system generations. Older binaries may continue to function but do not receive security updates.

## Maintenance policy

After 1.0, the maintainer reviews rclone and other dependency updates at least monthly and the automated security/dependency workflows run weekly. Provider-breaking or actively exploited security updates may ship sooner. Actionable GitHub Issues are triaged on a best-effort basis; correctness and security fixes ship as patch releases, while compatible features ship as minor releases.

Mountli is a free solo-maintainer project. It offers no enterprise SLA, hosted control plane, guaranteed response time, or guarantee of third-party storage-provider availability.

## Security model

- No Mountli account or benavo-hosted data plane.
- Credentials and remote configuration are encrypted on device.
- File transfers connect directly to user-selected providers.
- Apple File Provider owns local placeholders and protected materialization.
- Runtime rclone plugins, subprocesses, RC endpoints, macFUSE, and privileged helpers are not supported.
- Diagnostics exclude credentials, raw options, file contents, and cleartext paths by default.

Mountli cannot protect data from a compromised operating system, unlocked user session, malicious storage provider, or credentials exported by the user. Swift and Go runtimes cannot guarantee memory zeroization.
