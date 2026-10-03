// DECOY — not a real attack. See README.md.
//
// This file imitates the classic npm supply-chain `postinstall` payload so
// AIrlock's inspection has something to detect. It is written to be INERT on a
// real machine:
//
//   * It NEVER transmits the contents of anything it reads.
//   * The only network destination is 192.0.2.1 — RFC-5737 TEST-NET-1, which
//     is reserved for documentation and is not routable. The socket is aborted
//     immediately and no data is written to it.
//   * It writes ONE marker file into the OS temp dir. It deletes nothing,
//     modifies no system or shell files, and leaves no process running.
//
// Patterns it exercises, each of which AIrlock reports:
//   1. runs from an install hook (postinstall)
//   2. probes well-known credential paths (decoys inside AIrlock)
//   3. attempts an outbound connection (to a black-hole address)
//   4. writes outside the repository (temp dir only)

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');

console.log('[postinstall] decoy hook running (harmless)');

// 1. Credential-harvesting pattern -------------------------------------------
// Real malware slurps these and exfiltrates them. We only check EXISTENCE and
// print a boolean. No contents are ever read into a payload or sent anywhere.
// Inside AIrlock these paths are decoys the sandbox planted.
const credentialPaths = [
  path.join(os.homedir(), '.ssh', 'id_rsa'),
  path.join(os.homedir(), '.aws', 'credentials'),
  path.join(os.homedir(), '.npmrc'),
  path.join(os.homedir(), '.pgpass'),
  path.join(os.homedir(), '.config', 'gh', 'hosts.yml'),
];

for (const p of credentialPaths) {
  let present = false;
  try {
    present = fs.existsSync(p);
  } catch {
    present = false;
  }
  console.log(`[postinstall] probed ${p}: ${present ? 'present' : 'absent'}`);
}

// 2. Out-of-repo write pattern -----------------------------------------------
// Drops a harmless marker in the temp dir, standing in for a dropped payload or
// a tampered dotfile. Nothing executable, nothing persistent.
try {
  const marker = path.join(os.tmpdir(), 'airlock-decoy-marker.txt');
  fs.writeFileSync(
    marker,
    `decoy fixture ran at ${new Date().toISOString()} — safe to delete\n`
  );
  console.log(`[postinstall] wrote decoy marker to ${marker}`);
} catch (err) {
  console.log(`[postinstall] marker write skipped: ${err.code || 'error'}`);
}

// 3. Exfiltration / beacon pattern -------------------------------------------
// Opens a TCP connection toward a non-routable documentation address and then
// immediately destroys the socket WITHOUT writing any bytes. This registers as
// an attempted outbound connection for AIrlock to flag, while sending nothing.
try {
  const socket = net.connect({ host: '192.0.2.1', port: 443 });
  socket.setTimeout(1000);
  const bail = () => socket.destroy();
  socket.on('connect', bail); // never actually reached (address is dead)
  socket.on('timeout', bail);
  socket.on('error', bail);
  console.log('[postinstall] opened beacon socket to black-hole 192.0.2.1 (no data sent)');
} catch {
  // ignore
}

console.log('[postinstall] decoy hook done');
