# Connecting Herdr Desktop to WSL

*2026-11-13*

Herdr Desktop on Windows is a client. The terminals and agents run in herdr-core, so to use it with WSL you need herdr-core inside WSL and a way for the app to reach it. That way is SSH to `localhost`, which WSL forwards to the Linux side.

[claudelator](https://github.com/vivainio/claudelator) does the setup. Run it in your own WSL shell, not as root and not inside a sandboxed agent:

```bash
uv tool install claudelator
claudelator herdr --dry-run   # preview, changes nothing
claudelator herdr             # do it
claudelator herdr check       # sshd, connections, herdr-core processes, hc ls
```

It does these steps, skipping any that are already done:

1. Installs herdr-core (`hc`) if missing.
2. Installs and starts the OpenSSH server in WSL.
3. Creates a dedicated ed25519 key `herdr_desktop_ed25519` in your Windows `.ssh` folder, with no passphrase.
4. Adds the key's path to `sandbox.filesystem.denyRead` in `~/.claude/settings.json`, so a sandboxed Claude Code cannot read it.
5. Authorizes the public key in WSL.
6. Adds a `Host wsl` entry to the Windows SSH config. Use `--host` and `--port` to change the alias and port.
7. Tests key login to `localhost`, then turns off SSH password login. If the test fails, it stops and leaves password login on.

Then add the machine yourself: in Herdr Desktop open **Settings → Machines → Add machine** and pick `wsl`.

Because the key has no passphrase, anyone who can read the key file gets a shell as you. That is why step 4 hides it from the sandbox. Don't expose port 22 through an open firewall rule.

## Related

- [What is Herdr Desktop?](herdr-desktop.md) — the desktop app's architecture.
- [Herdr Tutorial](herdr.md) — the terminal version of Herdr.
