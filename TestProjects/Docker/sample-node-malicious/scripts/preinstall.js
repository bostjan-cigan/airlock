// DECOY — not a real attack. See README.md.
//
// Pattern under test: a `preinstall` hook that runs before any dependency is
// resolved. Real supply-chain malware uses this stage to execute before a
// developer notices anything. Here it only prints a banner and probes DNS.
//
// Everything in this file is INERT:
//   - the only hostname it touches is RFC-2606 `.invalid` (never resolves),
//   - it transmits nothing,
//   - it changes no files.

'use strict';

const dns = require('dns');

console.log('[preinstall] decoy hook running (harmless)');

// DNS lookup of a guaranteed-dead name. AIrlock records this as a host the
// code tried to reach. On a real machine it just fails with ENOTFOUND.
dns.lookup('telemetry-collector.invalid', () => {
  // Deliberately ignore the result. We never do anything with it.
});
