# Sekigetsu's VM Setup

## Installation:

On a fresh Arch Linux install, log in as the user you made while installing and run:

```
sudo pacman -S git
git clone https://github.com/sekigetsu01/SVS.git
cd SVS/static
sudo sh svs.sh
```

If that user can't use sudo yet (a hand-made install has no sudo until SVS sets it up), do the same as root:
`pacman -S git`, clone it the same way, and run `sh svs.sh`; it finds your user by itself.

SVS sets up that user: no new username or password to enter (if there's no user yet, it makes one). It asks a few things at the start
(whether to install the closed source programs, see below; h and l, or the arrows, pick a button; y and n answer yes or no; Backspace goes back),
shows what it's about to do, and then
runs by itself with a progress bar and the time left. When it's done, it lists anything that didn't
install, and after a reboot you go straight into the desktop, no login needed.

It also asks for a passphrase for a new SSH key (twice; Skip makes none). The passphrase stays in
memory only. The key is `~/.ssh/id_ed25519` (ed25519), never made over one you already have, and
the end screen shows its public key for GitHub (`cat ~/.ssh/id_ed25519.pub`). The dotfiles turn on
openssh's `ssh-agent` and their `sys-setup` adds `AddKeysToAgent yes` to `~/.ssh/config`, so you type
the passphrase once per login. With `-y` no key is made.

Before anything else it checks that this is Arch Linux, that there's internet and at least
10 GB free, and that pacman isn't busy, and stops with a clear message if not.

Options:

```
sudo sh svs.sh -y          no questions: installs everything, closed source included
sudo sh svs.sh -y -n       no questions, and no closed source software
sudo sh svs.sh -u NAME     set up NAME (when there's more than one user)
```

## What is SVS?

SVS is a script that autoinstalls and autoconfigures a minimal terminal-and-vim-based
Arch Linux environment that runs on wayland.
SVS is inspired by [LARBS](https://github.com/LukeSmithxyz/LARBS).

SVS can be run on a fresh install of Arch linux and provides you
with a fully configured diving-board for work or more customization.

## Why SVS
- Modern - uses Wayland and the native apps made for it.
- Minimal - uses mangowm and other small and efficient software.
- Privacy - Uses minimal and foss software.

## Customization

By default, SVS uses the programs [here in progs.csv](static/progs.csv) and installs
[my dotfiles repo here](https://github.com/sekigetsu01/mangorice), and puts
[my wallpapers](https://github.com/sekigetsu01/wallpapers) in `~/wallpapers`. Once the dotfiles are in
place it runs their `update`, which runs `sys-setup` (the rest of the system), installs the nvim and yazi
plugins and cleans up, as on every update after that.

### The `progs.csv` list

SVS will parse the given programs list and install all given programs. Note
that the programs file must be a three column `.csv`. SVS uses the `progs.csv` next to
`svs.sh`, so your edits are used straight away (the copy on GitHub only if there isn't one).

The first column is a "tag" that determines how the program is installed, ""
(blank) for the main repository, `A` for installation via the AUR, or `F` to install a flatpak.

Add `C` to the tag (`AC`, `C`, `FC`…) for closed source software. SVS first asks
"Do you want closed source software?": no installs none of them; yes asks about each of these programs on
its own (now only Vesktop).
Backspace on the first question goes back to the one before it (the SSH key, or the welcome screen); on the others, back to the first question. Whatever isn't installed has its configs from
the dotfiles deleted too; a program that's already installed keeps its configs (SVS never uninstalls anything).

The second column is the name of the program in the repository, and the third
column is a description (should be a verb phrase) that describes the program. During installation, SVS will print out
this information in a grammatical sentence. It also doubles as documentation
for people who read the CSV and want to install my dotfiles manually.

SVS installs every repo program (blank tag) first, all in one pacman run, then the others one by one, from the
top of the list to the bottom.

If you include commas in your program descriptions, be sure to include double
quotes around the whole description to ensure correct parsing.

### The script itself

The script is extensively divided into functions for easier readability and
trouble-shooting. Most everything should be self-explanatory.

The main work is done by `install_all`, which runs under the progress bar. It updates the
system first, then installs every repo package in one pacman run (much faster than one at a
time; any name pacman doesn't know is tried on its own, so one bad name doesn't stop the rest),
then goes through the other programs one by one, choosing how to install each from its tag
(`other_packages`). New methods of installation and tags go there.

At the end it runs the dotfiles' `update` (sys-setup, plugins, then its clean-up: orphaned packages, package
and build caches, old temp files).

Everything the installs print goes to `/var/log/svs.log`. If anything fails to install,
SVS lists it at the end, and the log says why.

Note that programs from the AUR can only be built by a non-root user. What
SVS does to bypass this by default is to temporarily allow the user to use
`sudo` without a password (so you won't be prompted for a password multiple
times in installation). This is done ad-hocly, but effectively, and removed at
the end of installation, leaving only exactly `sudo pacman -Syu` (nothing added to it) without a password.
`update` still asks for yours once, at the start.
It also puts the user in the `input` group, so the clicker records macros without a password, and lets
the VPN start without one (the VPN's own setup, done once here instead of on its first start).

## Autologin

SVS sets this up itself: it copies `~/.config/ly/config.ini` from the dotfiles to
`/etc/ly/config.ini` with your username filled in, and enables `ly@tty1.service`.
It takes over at the next boot.

## Running it again on a machine that's set up

You can run SVS again on a machine it (or SHS) set up before, to bring the dotfiles and programs up
to date. It installs only what's missing and leaves alone what it doesn't set up itself: VMs and
`~/VMs`, libvirt, Whonix, DNSCrypt and `/etc/resolv.conf`, and the Caps Lock remap. It copies the dotfiles over
yours again, except the few files their scripts change (`KEEP` in `svs.sh`: `~/.config/times.conf`, the timers'
`times.conf`, `kp`'s and the clicker's settings): those it only adds when missing.
The login at boot stays as it was: automatic, or ly asking for your password (as SHS sets it up without an encrypted
disk). The firewall that `sys-setup` puts in lets your VMs (`virbr*`) through and leaves libvirt's
own rules alone, and where SHS made kernel messages readable without sudo, that stays too.
