# sample-node-malicious (DECOY fixture)

A **deliberately suspicious** test package for exercising AIrlock's
`inspect_repo` detectors. It is **not** real malware.

> [!WARNING]
> The install hooks only fire on `npm install` / `pnpm install`. **Inspect this
> in AIrlock, not by installing it on your Mac.** It is designed to be inert
> even if that happens, but the point of the fixture is to run it in the sealed
> VM.

## What it imitates

It reproduces the shape of a classic npm supply-chain attack, split across a
`preinstall` and a `postinstall` hook:

| Pattern | Where | AIrlock should report |
| --- | --- | --- |
| Code runs from an install hook | `preinstall` + `postinstall` scripts | "Packages with install scripts" / hook output |
| DNS lookup of a C2-style host | `scripts/preinstall.js` | host looked up: `telemetry-collector.invalid` |
| Probing credential files | `scripts/postinstall.js` | decoy credential files read (`~/.ssh/id_rsa`, `~/.aws/credentials`, `~/.npmrc`, `~/.pgpass`, gh hosts) |
| Outbound beacon | `scripts/postinstall.js` | connection attempt to `192.0.2.1` |
| Writing outside the repo | `scripts/postinstall.js` | file changed outside the repository (temp dir marker) |

## Why it is safe on a real machine

- **No data leaves.** It never reads credential *contents* into a payload and
  never writes any bytes to a socket. It only checks whether paths exist.
- **No routable destinations.** The only hosts it touches are `.invalid`
  (RFC 2606, never resolves) and `192.0.2.1` (RFC 5737 TEST-NET-1, not
  routable). Both fail harmlessly.
- **No damage.** It writes a single throwaway marker to the OS temp dir. It
  deletes nothing, touches no shell/system files, spawns no process, and leaves
  nothing running.

## How to inspect it

Hand it to AIrlock's repository inspection (sealed VM, network closed before the
scripts run). Expect a report flagging the install hooks, the credential-path
reads against AIrlock's planted decoys, the blocked lookups/connection, and the
out-of-repo write — all while nothing actually leaves the VM.
