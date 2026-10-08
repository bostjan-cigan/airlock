# Security

AIrlock exists to keep an unattended AI agent, and the code it runs, away from your Mac. A way around that is the
most important kind of bug it can have.

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/bostjan-cigan/airlock/security/advisories/new), not
in a public issue. Include the version, the runtime (Docker or Apple VM), the task's network mode and workspace
(isolated clone, worktree or plain folder), and the steps or repository that show it.

You'll get a reply within a week. Once a fix is released, the advisory is published with credit to you, unless you'd
rather stay anonymous.

Only the latest release gets security fixes.

## What AIrlock defends against

The agent, and anything it runs or installs, is treated as hostile from the moment it starts. It may have been
steered by a prompt injection in the repository, an issue or a web page, or a dependency may be malicious. AIrlock
is built so that such an agent can't:

- **read or change your files.** The task works on its own copy of the repository, in a container or a VM. Your
  repository's objects are mounted read-only; refs, index, config and hooks are the task's own.
- **move your branches or reach your repository.** Git runs inside the container. Work comes out as a `git bundle`
  into a repository AIrlock keeps for the task, and reaches yours only when you hand it off, never with `--force`.
- **run code on your Mac through files it writes.** The Mac never runs git in, follows links in, or takes settings
  from anything the agent can write. Hook events, transcripts and the agent's settings are read without following
  symlinks, as regular files only, with a size cap.
- **steal your Claude credential.** The agent holds a placeholder. A proxy running as its own user adds the real
  token, and only that user may connect to the API.
- **send data where you haven't allowed it.** Sealed and restricted tasks resolve only allowlisted names, and the
  firewall admits only their addresses. Dependencies install with the network closed.
- **widen its own access.** More hosts, an open network, GitHub access and forwarded ports need **Allow** in the
  AIrlock window. A chat's request isn't enough on its own, since the chat may be repeating the agent's text.
- **mislead you through its messages.** Agent text is cleaned and always shown as untrusted, in the app and in the
  chat.

[How it's built › Isolation](README.md#isolation) in the README covers how each of these works.

## Limitations

These are known and accepted for now. Keep them in mind when you choose a task's settings.

- **Code you hand off is code you run.** Handing off brings the agent's commits into your repository. The review
  flags files that run on your Mac, in CI or steer agents (`package.json` scripts, lockfiles, workflows, hooks,
  `.envrc`, `.vscode/`, `CLAUDE.md`, `.mcp.json`), but it can't judge the code itself. Read it like a pull request
  from a stranger before you merge, build or run it.
- **Allowed hosts are ways out.** Every host you allow can receive data: a package registry accepts uploads, and
  GitHub accepts gists and pushes. Domains served from shared CDN addresses can make other sites on those addresses
  reachable too. **Open** network has no limit at all.
- **GitHub access gives the agent your token.** A task started with GitHub access gets your GitHub token as
  `GH_TOKEN` and can do anything that token allows. Use a fine-grained token limited to the repositories you need,
  or leave GitHub access off and push yourself.
- **Your code goes to Anthropic.** The agent sends what it reads to the Claude API, as any Claude Code session does.
- **Docker containers share a kernel.** Tasks on Docker run in one Linux VM, so a kernel exploit there reaches the
  other tasks in it. Each Apple VM has its own kernel. Choose Apple VMs for untrusted repositories.
- **Worktrees put the agent's files on your Mac.** A worktree task's files live in a folder on your Mac, so tools
  that open them can act on what the agent wrote: an editor applying workspace settings, or a shell running
  `.envrc`. AIrlock's own **Open in Terminal** and **Open in VS Code** wait until the task is stopped and its git
  settings are unchanged. The default isolated clone keeps everything in the container.
- **Compose bind mounts are checked, then mounted.** In worktree mode a bind mount is resolved and checked to stay
  inside the checkout, and Docker mounts it moments later. An agent that swaps a folder for a link in between
  could point it elsewhere on your Mac. Isolated clones don't bind-mount from your Mac.
- **Compose images come from outside the sandbox.** Your Mac's Docker pulls service images, outside the task's
  network policy. A repository's `compose.yaml` picks which images those are.
- **Forwarded ports reach your browser.** A forwarded port is `localhost` only, but whatever the task serves there
  runs in your browser like any local site.
- **A clean inspection report isn't proof.** An inspection shows what code did with the network closed and decoys
  in place. Code can wait, detect that it's being watched, or act only when it's used.
- **Releases aren't notarized.** Builds are signed ad hoc by GitHub Actions from this repository's source. Check the
  download against `SHA256SUMS.txt`, or build it yourself.
