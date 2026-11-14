# Connecting Herdr Desktop to WSL

*2026-11-13*

This guide connects the Herdr Desktop app on Windows to herdr-core running inside a WSL2 Linux distribution. The app is a client. The terminals and agents run in the core, so the WSL side needs herdr-core installed, and the desktop app needs a way to reach it. Here that way is SSH to `localhost`, which WSL forwards to the Linux side.

## The short way: `claudelator herdr`

Everything below except the last app step is scripted in [claudelator](https://github.com/vivainio/claudelator). Run it in your own WSL shell, not as root and not inside a sandboxed agent:

```bash
uv tool install claudelator
claudelator herdr --dry-run   # preview, changes nothing
claudelator herdr             # do it
claudelator herdr check       # sshd, connections, herdr-core processes, hc ls
```

It installs `hc` and the SSH server if missing, creates the key, authorizes it, adds the `Host wsl` entry to the Windows SSH config, and turns off password login. Each step is skipped when it is already done. Password login is only turned off after a key login to `localhost` succeeds, so a bad key cannot lock you out. You still add the machine in the app yourself (Step 6).

Two differences from the manual steps:

- **The key has no passphrase.** The script runs unattended, so it creates the key without one. That makes the key file as good as a login: anyone who can read it gets a shell as you. To limit that, the script also adds the key's path to `sandbox.filesystem.denyRead` in `~/.claude/settings.json`, so a sandboxed Claude Code cannot read it. If you want a passphrase, follow the manual steps instead.
- **Lockdown is not optional.** The manual steps treat turning off password login as a step you can postpone. The script always does it, after the key test.

I have only run the script's dry run against a setup that was already working. I have not run it on a fresh WSL.

## The manual way

The manual steps below are what I did, in order. Each one was checked with a command along the way. The last section lists what I could not verify.

## What you need

- Windows 11 with WSL2 and an Ubuntu distribution. I used Ubuntu 24.04.
- herdr-core installed inside WSL, which provides the `hc` command. Install it on Linux with:

  ```sh
  curl -fsSL https://releases.herdr.dev/core/install.sh | sh
  ```

  Check it with `command -v hc` and `hc --version`. Update it later with `hc update`. In my setup `hc` was 0.1.21 in `~/.local/bin`. The desktop app starts its own herdr-core in WSL over SSH, so herdr-core must be installed there.
- Herdr Desktop installed on Windows.
- Windows OpenSSH client (`ssh` and `ssh-keygen` on the PATH). Windows 11 includes it.

Herdr's Windows beta documentation describes running Herdr natively on Windows. It does not describe attaching the desktop app to a WSL server. The route below is the one I could verify.

## Why not just use a WSL terminal

Opening a WSL terminal, such as in Windows Terminal or WezTerm, and working with herdr-core there gives you a session in that terminal. It does not attach the Herdr Desktop window to WSL. The desktop app connects to a machine, and it only lists machines it can reach over SSH. So the desktop route needs an SSH server in WSL.

## Step 1: Install and start the SSH server in WSL

In a WSL shell:

```bash
sudo apt update
sudo apt install -y openssh-server
sudo service ssh start
```

Confirm it is listening on port 22:

```bash
ss -ltn | grep ':22'
```

You should see `0.0.0.0:22` and `[::]:22`. Starting the service with `service ssh start` lasts until WSL shuts down. To start it automatically, enable the `ssh` service in systemd if your distribution runs systemd.

## Step 2: Create a dedicated key on Windows

Make a separate key for the desktop app, so it can be revoked without touching your other keys. In a Windows terminal:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\herdr_desktop_ed25519" -C herdr-desktop
```

Set a passphrase when asked. The private key stays on Windows. Only the `.pub` file goes into WSL.

## Step 3: Authorize the public key in WSL

Run this in WSL. It reads the public key straight from the Windows folder, so there is nothing to copy and paste. Replace `<you>` with your Windows user name:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
PUB=/mnt/c/Users/<you>/.ssh/herdr_desktop_ed25519.pub
grep -qxF "$(cat "$PUB")" ~/.ssh/authorized_keys 2>/dev/null || cat "$PUB" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

The `grep` check means you can run it again without adding the key twice.

Then test the key from Windows. It asks for the passphrase, not a password:

```powershell
ssh -i "$env:USERPROFILE\.ssh\herdr_desktop_ed25519" <your-wsl-user>@localhost
```

If that logs you into the WSL shell, the key works.

## Step 4: Turn off password login

Do this only after the key login works, and keep your current session open until you have confirmed key login from a second terminal. Otherwise a mistake here can lock you out.

In WSL:

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo service ssh restart
```

Check the result:

```bash
grep -n '^\s*#\?\s*PasswordAuthentication' /etc/ssh/sshd_config
```

The uncommented line should read `PasswordAuthentication no`.

## Step 5: Add an SSH host for the desktop app

The desktop app lists machines from named SSH config hosts. Add an entry to the Windows SSH config file at `%USERPROFILE%\.ssh\config`:

```
Host wsl
    HostName localhost
    Port 22
    User <your-wsl-user>
    IdentityFile ~/.ssh/herdr_desktop_ed25519
```

The alias `wsl` is arbitrary. It is the name you will pick in the app.

## Step 6: Add the machine in Herdr Desktop

In the app, open **Settings → Machines** and choose **Add machine**. The picker lists your SSH config hosts. Pick `wsl`.

If the app asks for a passphrase or a password, it shows a command to run in your own terminal. Run it there, then return to the app. Herdr's own guide, `AGENTS.md` in the app's configuration folder, says machines that need a login or herdr-core show the command to run.

## Step 7: Check the connection

What I could check from the WSL side, after adding the machine in the app:

```bash
ss -tnp | grep ':22 '
ps -eo pid,lstart,args | grep '[h]erdr-core'
hc ls
```

Two established connections on port 22 meant the desktop app had connected over SSH. The process list then showed `herdr-core serve`, `herdr-core connect` and `herdr-core hold` processes that started at the moment the machine was added. Those are the core the app uses. `hc ls` talked to that core and showed no terminals, as expected before any space exists.
To confirm the desktop app is really attached, create a space on the `wsl` machine from the app. Then run `hc ls` again. The new terminal should appear there.

## What I did not verify

- **Whether a space created in the desktop app appears in `hc ls`.** I checked the SSH connection and the empty core. I did not confirm a space end to end.
- **The app's exact screens.** I described the Machines and Add machine steps from the app's own guide file. I did not see the screens myself.
- **Whether the connection survives a WSL restart or a reboot.** The SSH service needs to start again, and the app needs to reconnect.
- **Whether the `herdr-core` processes belong to the app's own session.** Their start time matched when I added the machine, which is strong evidence but not proof. Confirm by checking that a space's terminals appear in `hc ls`.
- **The relationship between `hc` and `herdr-core`.** I used `hc` for CLI checks, and the processes are named `herdr-core`. I did not confirm from the binaries whether `hc` is a symlink or a separate program.

## Security notes

- Use a dedicated key with a passphrase for the desktop app. Don't reuse the key you use for GitHub or other servers.
- Turn off password login before relying on this. The sshd service listens on port 22, and any password can be guessed.
- `localhost` only reaches WSL through the WSL port forward on your machine. Don't expose port 22 to a network with an open firewall rule.
- Keep the WSL user's password for `sudo`. Key login does not replace it for administrative steps.

## Related

- [What is Herdr Desktop?](herdr-desktop.md) — the desktop app's architecture.
- [Herdr Tutorial](herdr.md) — the terminal version of Herdr.
