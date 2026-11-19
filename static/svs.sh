#!/bin/bash
# SVS - Sekigetsu's VM Installer
# Run on a fresh Arch Linux installation, from the user you made while installing:
#   sudo sh svs.sh            asks a few questions first, then runs by itself
#   sudo sh svs.sh -y         no questions: installs everything, closed source included
#   sudo sh svs.sh -y -n      no questions, and no closed source software
#   sudo sh svs.sh -u NAME    set up NAME (when there's more than one user)
# It sets up that user (no new username or password needed) and logs it in automatically at boot.

# Run with bash (not bash's sh mode) even when started with 'sh svs.sh'.
if [ -z "$BASH_VERSION" ] || shopt -qo posix 2>/dev/null; then exec bash "$0" "$@"; fi


# CONFIGURATION

DOTFILES="https://github.com/sekigetsu01/mangorice.git"
WALLPAPERS="https://github.com/sekigetsu01/wallpapers.git"   # into ~/wallpapers
PROGSFILE="https://raw.githubusercontent.com/sekigetsu01/SVS/main/static/progs.csv"
AURHELPER="yay"
BRANCH="main"
SESSION="mango"            # desktop session ly logs into automatically
LOG=/var/log/svs.log       # everything the installs print, to see why something failed
MIN_FREE_GB=10             # free space needed on /
WORK=/tmp/svs              # the programs list and progress while it runs
# whiptail needs a description of the terminal: one this system has none for (kitty over ssh, say) is drawn as plain ANSI
infocmp "$TERM" >/dev/null 2>&1 || export TERM=ansi
# Dark screens that stay readable in any terminal colours (pywal's too): light text only on black, black text on any
# colour. The progress bar's percentage is always white (newt), so both parts of the bar are dark: with 256 colours,
# shades that colour schemes don't change; on the console's 8, blue (dark there) and black
bar_full=blue bar_empty=black
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then bar_full=color24 bar_empty=color236; fi
export NEWT_COLORS="
root=lightgray,black
roottext=lightgray,black
helpline=lightgray,black
border=cyan,black
window=lightgray,black
shadow=black,black
title=cyan,black
textbox=lightgray,black
acttextbox=black,cyan
label=lightgray,black
button=black,lightgray
actbutton=black,cyan
compactbutton=lightgray,black
entry=black,cyan
disentry=lightgray,black
checkbox=lightgray,black
actcheckbox=black,cyan
listbox=lightgray,black
actlistbox=black,cyan
sellistbox=black,cyan
actsellistbox=black,cyan
emptyscale=lightgray,$bar_empty
fullscale=lightgray,$bar_full
"


# OPTIONS

yes=0 closed_default="" name=""
usage() {
	sed -n '4,7s/^#   //p' "$0" >&2
	exit 1
}
while [ $# -gt 0 ]; do
	case $1 in
		-y|--yes) yes=1 ;;
		-n|--no-closed) closed_default=no ;;
		-u|--user) name=$2; shift; [ -n "$name" ] || usage ;;
		-h|--help) usage ;;
		*) usage ;;
	esac
	shift
done


# UTILITIES

die() { clear 2>/dev/null; printf "svs: %s\n" "$1" >&2; exit 1; }


# whiptail with the step line at the top of the screen
BACK="SVS"
step_line() { BACK="SVS  ·  step $1 of 3: $2"; }
wt() {
	local a
	# typing (a name, passwords) and the progress bar: whiptail as it is, so h and l are just letters there
	for a; do
		case $a in --inputbox|--passwordbox|--gauge) whiptail --backtitle "$BACK" "$@"; return ;; esac
	done
	[ -t 0 ] && command -v script >/dev/null || { whiptail --backtitle "$BACK" "$@"; return; }
	wt_hl "$@"
}

# h / l move between the buttons (whiptail itself only knows the arrows and Tab): it runs in a terminal of its
# own (script), and the keys you press reach it through hl_keys, h and l turned into ← and →. What it picks (a menu)
# comes back through a file, out on stderr as whiptail puts it.
hl_keys() {
	local k
	while :; do
		IFS= read -rn1 -d '' k || continue
		case $k in h) printf '\e[D' ;; l) printf '\e[C' ;; $'\n') printf '\r' ;; *) printf '%s' "$k" ;; esac
	done
}
wt_hl() {
	local size saved in kp rc out=$WORK/wt-out
	size=$(stty size) saved=$(stty -g)
	stty -icanon -echo -icrnl min 1
	exec {in}< <(hl_keys)
	kp=$!
	SHELL=/bin/bash script -qefc "stty rows ${size% *} cols ${size#* }; exec whiptail --output-fd 3 $(printf '%q ' --backtitle "$BACK" "$@") 3>$(printf '%q' "$out")" /dev/null <&"$in"
	rc=$?
	kill "$kp" 2>/dev/null
	exec {in}<&-
	stty "$saved"
	[ -s "$out" ] && cat "$out" >&2
	rm -f "$out"
	return "$rc"
}

ask() {   # ask TITLE TEXT [HEIGHT]: yes / no question (yes with -y)
	(( yes )) && return 0
	wt --title "$1" --yes-button "Yes" --no-button "No" --yesno "$2" "${3:-9}" 70
}

pac() { pacman --noconfirm --needed "$@" >>"$LOG" 2>&1; }

# Description of a program in the list, without the quotes
describe() { awk -F, -v p="$1" '$2 == p { sub(/^[^,]*,[^,]*,/, ""); gsub(/^"|"$/, ""); print; exit }' "$WORK/progs.csv"; }


# CHECKS BEFORE ANYTHING ELSE

preflight() {
	(( EUID == 0 )) || die "run it with sudo: sudo sh svs.sh"
	command -v pacman >/dev/null && [ -f /etc/arch-release ] && [ -d /run/systemd/system ] ||
		die "this is for Arch Linux (no pacman, arch-release or systemd found)."
	curl -fsI --max-time 15 https://archlinux.org >/dev/null 2>&1 ||
		curl -fsI --max-time 15 https://github.com >/dev/null 2>&1 ||
		die "no internet connection (couldn't reach archlinux.org or github.com)."
	free=$(df -Pk / | awk 'NR == 2 { print int($4 / 1048576) }')
	(( free >= MIN_FREE_GB )) || die "not enough free space: ${free} GB on /, it needs at least ${MIN_FREE_GB} GB."
	# a pacman lock left by a crash (not one in use) would stop every install
	if [ -e /var/lib/pacman/db.lck ]; then
		pgrep -x 'pacman|yay|makepkg' >/dev/null && die "pacman is busy in another window: let it finish first."
		rm -f /var/lib/pacman/db.lck
	fi
	mkdir -p "$WORK" && : > "$LOG" || die "couldn't write $LOG"
	# whiptail itself
	# (from the package list the install left, not -Sy: refreshing it and installing one package is a partial upgrade;
	# only when that list is too old to download from is the whole system updated first)
	command -v whiptail >/dev/null || pacman --noconfirm -S --needed libnewt >>"$LOG" 2>&1 ||
		pacman --noconfirm -Syu --needed libnewt >>"$LOG" 2>&1 ||
		die "couldn't install whiptail (libnewt); see $LOG"
	# set up before, by svs or shs (their sudo rules are there and ly is on): the login at boot stays as it is,
	# automatic or with a password (shs asks for one on a host without an encrypted disk)
	already=0 autologin=1
	if [ -f /etc/sudoers.d/01-passwordless-cmds ] &&
		{ systemctl is-enabled -q ly@tty1.service || systemctl is-enabled -q ly.service; } 2>/dev/null; then
		already=1
		grep -qE '^[[:space:]]*auto_login_user[[:space:]]*=' /etc/ly/config.ini 2>/dev/null || autologin=0
	fi
}


# QUESTIONS

welcome() {
	(( yes )) && return 0
	wt --title "Welcome to SVS!" --yes-button "Continue" --no-button "Cancel" --yesno \
		"Welcome to Sekigetsu's VM Installer.\n\nThis sets up a full desktop for your user: programs, dotfiles, and logging in automatically.\n\nA few questions first, then it runs by itself.\n\n-Sekigetsu" 14 65
}

# The user to set up: -u NAME, else the one who ran 'sudo sh svs.sh', else the only user made during
# the Arch install, else a pick from the users there are. Only asks for a new username and password
# if there are no users at all.
get_user() {
	[ -n "$name" ] || name=${SUDO_USER:-}
	[ "$name" = root ] && name=""
	if [ -n "$name" ]; then
		id -u "$name" >/dev/null 2>&1 || die "there's no user called '$name'."
		return 0
	fi
	mapfile -t users < <(awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ "^/home/" { print $1 }' /etc/passwd)
	if (( ${#users[@]} == 1 )); then
		name=${users[0]}
	elif (( ${#users[@]} > 1 )); then
		(( yes )) && die "more than one user here: say which with -u NAME."
		local items=() u
		for u in "${users[@]}"; do items+=("$u" ""); done
		name=$(wt --title "Which user?" --nocancel --menu "Set up the desktop for:" 15 50 6 "${items[@]}" 3>&1 1>&2 2>&3) || exit 1
	else
		(( yes )) && die "there's no user yet: make one, or run it without -y to make one here."
		new_user=1
		get_credentials
	fi
}

get_credentials() {
	name=$(wt --inputbox "No user found. Enter a username for the new account." 10 60 3>&1 1>&2 2>&3) || exit 1
	until [[ $name =~ ^[a-z_][a-z0-9_-]*$ ]]; do
		name=$(wt --nocancel --inputbox "Invalid username. Use lowercase letters, numbers, - or _ only. Must start with a letter." \
			10 65 3>&1 1>&2 2>&3)
	done
	pass1=$(wt --nocancel --passwordbox "Enter a password for '$name'." 10 60 3>&1 1>&2 2>&3)
	pass2=$(wt --nocancel --passwordbox "Confirm password." 10 60 3>&1 1>&2 2>&3)
	while [ -z "$pass1" ] || [ "$pass1" != "$pass2" ]; do
		pass1=$(wt --nocancel --passwordbox "Passwords were empty or didn't match. Try again." 10 60 3>&1 1>&2 2>&3)
		pass2=$(wt --nocancel --passwordbox "Confirm password." 10 60 3>&1 1>&2 2>&3)
	done
}

# A passphrase for the new SSH key. It stays in this script's memory only (never on disk, in the
# log or on a command line) and is fed to ssh-keygen through a pipe. Skip: no key is made.
get_ssh_pass() {
	ssh_make=0 ssh_pass="" ssh_have=0
	local h p2
	h=$(getent passwd "$name" | cut -d: -f6)
	[ -n "$h" ] && [ -e "$h/.ssh/id_ed25519" ] && { ssh_have=1; return 0; }
	(( yes )) && return 0
	while :; do
		ssh_pass=$(wt --title "SSH key" --cancel-button "Skip" --passwordbox \
			"SVS makes you an SSH key (for GitHub and servers). Choose its passphrase: you type it once per login.\n\nSkip: no key." \
			12 68 3>&1 1>&2 2>&3) || { ssh_pass=""; return 0; }
		p2=$(wt --title "SSH key" --nocancel --passwordbox "Same passphrase again." 9 68 3>&1 1>&2 2>&3)
		if [ "$ssh_pass" != "$p2" ]; then
			wt --title "SSH key" --msgbox "The passphrases didn't match. Try again." 8 50
			continue
		fi
		[ -n "$ssh_pass" ] && break
		wt --title "SSH key" --yes-button "No passphrase" --no-button "Back" --yesno \
			"No passphrase?\n\nAnyone who gets a copy of the key file can use it." 10 60 && break
	done
	unset p2
	ssh_make=1
}

# In a virtual machine: public if it gets closed source software, else private. backup copies to the computer it
# runs on, into ~/backups/public or ~/backups/private there (~/.config/backup/vm)
get_vm_kind() {
	vm_kind=""
	systemd-detect-virt -q --vm 2>/dev/null || return 0
	if (( ${#closed_yes[@]} )); then vm_kind=public; else vm_kind=private; fi
}

get_progs() {
	# The progs.csv next to this script if there is one (so your edits are used), else the one on GitHub.
	local here
	here=$(dirname "$(readlink -f "$0")")
	if [ -f "$here/progs.csv" ]; then
		cat "$here/progs.csv"
	else
		curl -fLs --max-time 60 "$PROGSFILE"
	fi | tr -d '\r' | sed '/^#/d;/^[[:space:]]*$/d' > "$WORK/progs.csv"
	[ -s "$WORK/progs.csv" ] || die "couldn't get the programs list (progs.csv)."
}

# Programs tagged C in progs.csv are closed source: ask before installing any of them, then one by one.
ask_closed_source() {
	local program shown
	mapfile -t closed < <(awk -F, '$1 ~ /C/ { print $2 }' "$WORK/progs.csv")
	skip=() closed_yes=()
	(( ${#closed[@]} )) || return 0
	if [ "$closed_default" = no ] || { (( ! yes )) && ! ask "Closed source software" "Do you want to install any of the closed source software?" 8; }; then
		skip=("${closed[@]}")
		return 0
	fi
	for program in "${closed[@]}"; do
		shown=$(pretty "$program")
		if ask "Closed source software" "Install $shown?\n\n$shown $(describe "$program")" 10; then
			closed_yes+=("$shown")
		else
			skip+=("$program")
		fi
	done
}

# A program's name as people write it: vesktop-bin -> Vesktop
pretty() {
	local p
	p=$(sed -E 's/-(bin|git)$//' <<< "$1")
	echo "${p^}"
}

# The list of what to install, split by how
plan() {
	local tag program s
	repo=() other=()
	while IFS=, read -r tag program _; do
		for s in "${skip[@]}"; do [ "$s" = "$program" ] && continue 2; done
		case ${tag//C/} in
			"") repo+=("$program") ;;
			*) other+=("$tag,$program") ;;
		esac
	done < "$WORK/progs.csv"
}

summary() {
	local aur=0 flat=0 rest=0 t minutes closed_text
	for t in "${other[@]}"; do
		case ${t%%,*} in A|AC) aur=$((aur + 1)) ;; F|FC) flat=$((flat + 1)) ;; *) rest=$((rest + 1)) ;; esac
	done
	# rough: the system update and repo packages, each AUR build, and sys-setup
	minutes=$(( 8 + ${#repo[@]} / 15 + aur * 2 + flat + rest + 12 ))
	closed_text=${closed_yes[*]:-none}
	if (( ! already )); then login_text="automatic login"
	elif (( autologin )); then login_text="automatic login (as it is)"
	else login_text="the login screen as it is (with your password)"; fi
	(( yes )) && return 0
	if (( ssh_have )); then ssh_text="the one you have (~/.ssh/id_ed25519)"
	elif (( ! ssh_make )); then ssh_text="none (skipped)"
	elif [ -n "$ssh_pass" ]; then ssh_text="a new one, with your passphrase"
	else ssh_text="a new one, no passphrase"; fi
	wt --title "Ready to install" --yes-button "Start" --no-button "Cancel" --yesno \
"For:            $name$([ -n "${new_user:-}" ] && echo " (new user)")
Programs:       ${#repo[@]} from the Arch repos, $aur from the AUR, $flat flatpaks$( (( rest )) && echo ", $rest other")
Closed source:  ${closed_text// /, }
SSH key:        $ssh_text$([ -n "$vm_kind" ] && printf '\nBackups:        host:~/backups/%s' "$vm_kind")
Then:           your dotfiles, $login_text, then your update (sys-setup, plugins)

Roughly $minutes minutes, depending on your internet.
It runs by itself from here. The log is $LOG." 17 76
}


# THE INSTALL (runs under the progress bar; everything it prints goes to the log)

# progress: everything has a weight; the bar shows how much of the total weight is done
progress_init() {
	local t
	total_w=$(( 6 + 1 + 3 + ${#repo[@]} + 2 + 2 + 1 + 2 + 17 ))
	for t in "${other[@]}"; do
		case ${t%%,*} in A|AC|S|SC) total_w=$((total_w + 4)) ;; *) total_w=$((total_w + 3)) ;; esac
	done
	done_w=0 started=$(date +%s)
}
show() {   # show LINE1 [LINE2]: what it's doing now, with the bar
	local pct left="" elapsed
	pct=$(( done_w * 100 / total_w )); (( pct > 99 )) && pct=99
	elapsed=$(( $(date +%s) - started ))
	if (( pct >= 5 && elapsed > 60 )); then
		left=$(( elapsed * (total_w - done_w) / done_w / 60 + 1 ))
		left="  ·  about $left min left"
	fi
	# one text line, with whiptail's own \n for the line breaks
	printf 'XXX\n%d\n%s%s\\n\\n%s\nXXX\n' "$pct" "$1" "$left" "${2:-}" >&3
}
advance() { done_w=$(( done_w + $1 )); }
fail() { echo "$1" >> "$WORK/failed"; }

update_system() {
	show "Updating the system" "keyring, then all packages (a fresh install's packages can be old)"
	pac -Sy archlinux-keyring
	# colour, 5 downloads at once, all CPU cores for builds
	grep -q "ILoveCandy" /etc/pacman.conf || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
	sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf
	sed -i "s/-j2/-j$(nproc)/;/^#MAKEFLAGS/s/^#//" /etc/makepkg.conf
	# a full update before installing anything (installing onto an old system can break it)
	# (tried twice: a mirror that drops out is the usual reason; still failing, nothing else is installed)
	pacman -Syu --noconfirm >>"$LOG" 2>&1 || pacman -Syu --noconfirm >>"$LOG" 2>&1 ||
		{ fail "system update"; return 1; }
	advance 6

	# sudo too: everything after this runs your builds through it (an install logged in as root may not have it)
	show "Installing the basics" "curl, base-devel, git, zsh, sudo"
	pac -S curl ca-certificates base-devel git zsh sudo || fail "base-devel / git / zsh / sudo"
	timedatectl set-ntp true >>"$LOG" 2>&1
	advance 1
}

setup_user() {
	if [ -n "${new_user:-}" ]; then
		useradd -m -G wheel,input -s /bin/zsh "$name" >>"$LOG" 2>&1 || { fail "creating the user $name"; return 1; }
		echo "$name:$pass1" | chpasswd
		unset pass1 pass2
	else
		usermod -aG wheel,input "$name"
	fi
	chsh -s /bin/zsh "$name" >>"$LOG" 2>&1
	group=$(id -gn "$name")
	home=$(getent passwd "$name" | cut -d: -f6)
	export REPODIR="$home/.local/src"
	as_user mkdir -p "$REPODIR" "$home/Downloads" "$home/Pictures" "$home/Audiobooks" "$home/sync" "$home/github" "$home/.cache/zsh"
	# AUR builds run as you and need sudo for pacman: allowed without a password until the end. The lasting rule
	# (sudo with your password) goes in now too, so a stop half way (Ctrl+C, a crash) never leaves you without sudo
	# verifypw/listpw=any: 'sudo -v' (sys-setup, cleaner and update start with it) passes on this one passwordless rule;
	# by default every rule must be passwordless, so the lasting one made it ask, unseen behind the progress bar
	echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/00-wheel-sudo
	printf '%s\n' "Defaults verifypw=any, listpw=any" "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/svs-temp
	chmod 440 /etc/sudoers.d/00-wheel-sudo /etc/sudoers.d/svs-temp
}

as_user() { sudo -u "$name" -H "$@"; }

aur_helper() {
	show "Building $AURHELPER" "installs programs from the AUR"
	if ! command -v "$AURHELPER" >/dev/null; then
		local dir=$REPODIR/$AURHELPER
		rm -rf "$dir"
		as_user git clone --depth 1 -q "https://aur.archlinux.org/$AURHELPER.git" "$dir" >>"$LOG" 2>&1 &&
			(cd "$dir" && as_user makepkg -sif --noconfirm >>"$LOG" 2>&1) ||
			{ fail "$AURHELPER"; return 1; }
	fi
	advance 3
}

repo_packages() {
	# One pacman run for every repo package (much faster than one each). Names pacman doesn't know
	# (renamed or a typo) are tried on their own afterwards, so one bad name doesn't stop the rest.
	(( ${#repo[@]} )) || return 0
	local known=() unknown=() p line n m base=$done_w count=${#repo[@]}
	declare -A in_repos
	while read -r p; do in_repos[$p]=1; done < <(pacman -Slq 2>/dev/null)
	for p in "${repo[@]}"; do
		if [ -n "${in_repos[$p]:-}" ] || pacman -Sgq "$p" >/dev/null 2>&1; then known+=("$p"); else unknown+=("$p"); fi
	done
	show "Installing ${#known[@]} programs from the Arch repos" "downloading..."
	LC_ALL=C pacman -S --noconfirm --needed "${known[@]}" 2>&1 | tee -a "$LOG" | while IFS= read -r line; do
		# pacman prints "(12/340) installing name" for each package (dependencies included)
		if [[ $line =~ ^\(\ *([0-9]+)/\ *([0-9]+)\)\ (installing|upgrading|reinstalling)\ ([^ .]+) ]]; then
			n=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]}
			done_w=$(( base + count * n / m ))
			show "Installing from the Arch repos ($n of $m)" "${BASH_REMATCH[4]}"
		fi
	done
	if (( PIPESTATUS[0] )); then
		# the batch stopped (a conflict, say): one at a time, to find which
		unknown+=("${known[@]}")
	fi
	done_w=$(( base + count ))
	for p in "${unknown[@]}"; do
		pacman -Q "$p" >/dev/null 2>&1 && continue
		show "Installing $p" "$(describe "$p")"
		pac -S "$p" || fail "$p"
	done
}

other_packages() {
	local entry tag program i=0 n=${#other[@]} aur_done
	aur_done=$(pacman -Qqm 2>/dev/null)
	for entry in "${other[@]}"; do
		tag=${entry%%,*} program=${entry#*,} i=$((i + 1))
		show "$i of $n  ·  $(basename "$program" .git | sed -E 's/-(bin|git)$//')" "$(describe "$program")"
		case ${tag//C/} in
			A)
				grep -qx "$program" <<< "$aur_done" ||
					as_user "$AURHELPER" -S --needed --noconfirm --answerclean None --answerdiff None \
						--answeredit None --removemake --mflags --nocheck "$program" >>"$LOG" 2>&1 || fail "$program"
				advance 4 ;;
			S)
				local dir=$REPODIR/$program
				pacman -Q "$program" >/dev/null 2>&1 || {
					rm -rf "$dir"
					as_user git clone --depth 1 -q "https://aur.archlinux.org/$program.git" "$dir" >>"$LOG" 2>&1 &&
						(cd "$dir" && as_user makepkg -sif --noconfirm >>"$LOG" 2>&1)
				} || fail "$program"
				advance 4 ;;
			F)
				{ pac -S flatpak &&
					flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 &&
					flatpak install -y --noninteractive flathub "$program" >>"$LOG" 2>&1; } || fail "$program"
				advance 3 ;;
			G)
				local dir
				dir=$REPODIR/$(basename "$program" .git)
				{ if [ -d "$dir/.git" ]; then as_user git -C "$dir" pull -q --force >>"$LOG" 2>&1
				  else as_user git clone --depth 1 -q "$program" "$dir" >>"$LOG" 2>&1; fi &&
					as_user make -C "$dir" >>"$LOG" 2>&1 && make -C "$dir" install >>"$LOG" 2>&1; } || fail "$program"
				advance 3 ;;
			P)
				{ command -v pipx >/dev/null || pac -S python-pipx; } &&
					as_user pipx install "$program" >>"$LOG" 2>&1 && as_user pipx ensurepath >>"$LOG" 2>&1 || fail "$program"
				advance 3 ;;
			*)
				echo "unknown tag '$tag' for $program" >> "$LOG"; fail "$program (unknown tag $tag)"
				advance 3 ;;
		esac
	done
}

install_dotfiles() {
	show "Installing your dotfiles" "$DOTFILES"
	local tmp
	tmp=$(mktemp -d) && chown "$name:$group" "$tmp"
	if as_user git clone --depth 1 --single-branch --no-tags -q --recurse-submodules -b "$BRANCH" "$DOTFILES" "$tmp/d" >>"$LOG" 2>&1; then
		# the repo's own files stay out of your home folder
		rm -rf "$tmp/d/.git" "$tmp/d/README.md" "$tmp/d/LICENSE"
		find "$tmp/d" -name .git -prune -exec rm -rf {} + 2>/dev/null
		as_user cp -rfT "$tmp/d" "$home" >>"$LOG" 2>&1 || fail "copying the dotfiles"
		drop_skipped
	else
		fail "dotfiles (couldn't clone $DOTFILES)"
	fi
	rm -rf "$tmp"
	advance 2
}

# a closed source program you said no to: its configs go too, and what in other files is there only for it
drop_skipped() {
	local s c=$home/.config
	for s in "${skip[@]}"; do
		case $s in
			vesktop-bin)
				rm -rf "$c/vesktop" "$c/wal/vesktop-theme" "$c/wal/vesktop-base.css"
				sed -i "/^# Vesktop's theme/,/^$/d" "$c/wal/postrun" 2>/dev/null
				sed -i '/vesktop/d' "$c/mango/config.conf" "$c/mimeapps.list" 2>/dev/null ;;
		esac
	done
}

install_wallpapers() {
	show "Downloading the wallpapers" "$WALLPAPERS  →  ~/wallpapers"
	local tmp
	tmp=$(mktemp -d) && chown "$name:$group" "$tmp"
	if as_user git clone --depth 1 --single-branch --no-tags -q "$WALLPAPERS" "$tmp/w" >>"$LOG" 2>&1; then
		rm -rf "$tmp/w/.git" "$tmp/w/README.md" "$tmp/w/LICENSE"
		as_user cp -rfT "$tmp/w" "$home/wallpapers" >>"$LOG" 2>&1 || fail "copying the wallpapers"
	else
		fail "wallpapers (couldn't clone $WALLPAPERS)"
	fi
	rm -rf "$tmp"
	advance 2
}

setup_ssh() {
	# ~/.ssh, your key (never over one you have), and the agent: it keeps the key unlocked once
	# you've typed the passphrase, until you log out
	show "Setting up SSH" "your key, and the agent that remembers its passphrase"
	local d=$home/.ssh unit f wants agent=""
	as_user mkdir -p "$d" && chmod 700 "$d"
	if (( ssh_make )) && [ ! -e "$d/id_ed25519" ] && [ ! -e "$d/id_ed25519.pub" ]; then
		# no terminal (setsid), so ssh-keygen reads the passphrase from the pipe, not the screen
		printf '%s\n%s\n' "$ssh_pass" "$ssh_pass" |
			as_user env SSH_ASKPASS_REQUIRE=never setsid -w ssh-keygen -q -t ed25519 -a 100 \
				-C "$name@$(uname -n)" -f "$d/id_ed25519" >>"$LOG" 2>&1 || fail "SSH key"
	fi
	unset ssh_pass
	# the first time ssh uses the key, the agent keeps it
	[ -e "$d/config" ] || as_user sh -c 'umask 077 && printf "Host *\n\tAddKeysToAgent yes\n" > "$1"' _ "$d/config"
	# openssh's own agent unit, turned on the way 'systemctl --user enable' does it
	for unit in ssh-agent.socket ssh-agent.service; do
		f=/usr/lib/systemd/user/$unit
		[ -f "$f" ] || continue
		wants=$(sed -n 's/^WantedBy=[[:space:]]*//p' "$f" | head -n 1)
		wants=${wants%% *}
		case $unit in *.socket) wants=${wants:-sockets.target} ;; *) wants=${wants:-default.target} ;; esac
		as_user mkdir -p "$home/.config/systemd/user/$wants.wants" &&
			as_user ln -sf "$f" "$home/.config/systemd/user/$wants.wants/$unit" && agent=$unit
		break
	done
	[ -n "$agent" ] || fail "the SSH agent (no ssh-agent user unit from openssh)"
	advance 1
}

configure() {
	show "Setting things up" "automatic login, system settings"
	configure_autologin
	# no PC speaker beep
	rmmod pcspkr 2>/dev/null
	echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf
	as_user mkdir -p "$home/.local/share/gnupg" && chmod 700 "$home/.local/share/gnupg"
	advance 2
}

configure_autologin() {
	# ly logs you straight into the desktop at boot, without a username or password
	# (by its package: the program is ly-dm in newer ly, so a 'ly' command can't be looked for)
	pacman -Q ly >/dev/null 2>&1 || { fail "automatic login (ly isn't installed)"; return; }
	local keep=""
	mkdir -p /etc/ly
	# set up before: its own auto_login lines (or none: a password) stay
	(( already )) && keep=$(grep -E '^[[:space:]]*auto_login_(user|session)[[:space:]]*=' /etc/ly/config.ini 2>/dev/null)
	[ -f "$home/.config/ly/config.ini" ] && cp -f "$home/.config/ly/config.ini" /etc/ly/config.ini
	if [ -f /etc/ly/config.ini ]; then
		sed -i -E "/^[[:space:]]*auto_login_(user|session)[[:space:]]*=/d" /etc/ly/config.ini
		if (( already )); then
			[ -n "$keep" ] && printf '%s\n' "$keep" >> /etc/ly/config.ini
		else
			printf "auto_login_user = %s\nauto_login_session = %s\n" "$name" "$SESSION" >> /etc/ly/config.ini
		fi
	fi
	# lets ly log in without a password (ly ships this; older versions may not)
	[ -f /etc/pam.d/ly-autologin ] || cat > /etc/pam.d/ly-autologin << 'EOF'
#%PAM-1.0

auth       required     pam_permit.so
account    include      login
password   include      login
-session   optional     pam_systemd.so       class=greeter
session    include      login
EOF
	# ly takes over tty1 at the next boot (not now: that would close this session); newer ly is a service per tty
	# (ly@tty1), older ly one service (ly)
	local unit=ly@tty1.service
	[ -e /usr/lib/systemd/system/ly@.service ] || unit=ly.service
	systemctl disable getty@tty1.service >>"$LOG" 2>&1
	systemctl enable "$unit" >>"$LOG" 2>&1 || fail "automatic login (enabling $unit)"
}

finish() {
	# what only svs does, then your own update: sys-setup (the system side), nvim and yazi plugins, flatpaks,
	# the cleaner and its checks, as on every update after this
	local timer up=$home/.local/bin/update
	# Glide's Pywalfox helper (wallpaper colours)
	command -v pywalfox >/dev/null 2>&1 &&
		as_user pywalfox install --manifest-path "$home/.glide-browser/native-messaging-hosts" >>"$LOG" 2>&1
	# your timers (systemctl --user can't run from here): what 'enable' does, by hand. Not the backup in a virtual
	# machine: it has no backup drive (backup copies to the computer it runs on, by hand)
	timer=$home/.config/systemd/user/backup.timer
	if [ -f "$timer" ] && ! systemd-detect-virt -q --vm 2>/dev/null; then
		as_user mkdir -p "${timer%/*}/timers.target.wants"
		as_user ln -sf ../backup.timer "${timer%/*}/timers.target.wants/backup.timer"
	fi
	# public or private: which folder its backups go into on the computer it runs on
	[ -n "$vm_kind" ] && as_user mkdir -p "$home/.config/backup" && echo "$vm_kind" | as_user tee "$home/.config/backup/vm" >/dev/null
	if [ -f "$home/.local/lib/vpn-install" ]; then
		SUDO_USER=$name sh "$home/.local/lib/vpn-install" >>"$LOG" 2>&1 ||
			fail "VPN without a password (run: sudo sh ~/.local/lib/vpn-install)"
	fi
	advance 3

	if [ -x "$up" ]; then
		show "Running update" "system settings (sys-setup), nvim and yazi plugins, clean-up; it takes a while"
		as_user "$up" >>"$LOG" 2>&1 || fail "update (some steps: run update again after logging in)"
	else
		# dotfiles without update: their sys-setup and cleaner on their own
		show "Running sys-setup" "the rest of the system settings"
		[ -x "$home/.local/bin/sys-setup" ] && { as_user "$home/.local/bin/sys-setup" >>"$LOG" 2>&1 ||
			fail "sys-setup (some steps: run sys-setup again after logging in)"; }
		show "Cleaning up" "orphaned packages, package caches, build leftovers"
		[ -x "$home/.local/bin/cleaner" ] && { as_user "$home/.local/bin/cleaner" >>"$LOG" 2>&1 || fail "cleaner (some steps)"; }
	fi
	advance 14
}

configure_sudo() {
	# replaces the temporary no-password rule: password for sudo again, except these
	# (no passwordless mount / umount: those would let anyone in wheel become root)
	echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/00-wheel-sudo
	echo "%wheel ALL=(ALL:ALL) NOPASSWD: \
/usr/bin/shutdown,/usr/bin/reboot,/usr/bin/systemctl suspend,\
/usr/bin/pacman -Syu,/usr/bin/pacman -Syyu,/usr/bin/pacman -Syyu --noconfirm,\
/usr/bin/loadkeys,/usr/bin/pacman -Syyuw --noconfirm" > /etc/sudoers.d/01-passwordless-cmds
	echo "Defaults editor=/usr/bin/nvim" > /etc/sudoers.d/02-visudo-editor
	chmod 440 /etc/sudoers.d/0[012]-*
	rm -f /etc/sudoers.d/svs-temp
}

install_all() {
	progress_init
	update_system || return
	setup_user || return
	aur_helper
	repo_packages
	other_packages
	install_dotfiles
	install_wallpapers
	setup_ssh
	configure
	finish
	done_w=$total_w
	printf 'XXX\n100\nDone\nXXX\n' >&3
}


# MAIN

preflight
trap 'rm -f /etc/sudoers.d/svs-temp; rm -rf "$WORK"; [ -t 0 ] && stty sane' EXIT
trap 'exit 1' HUP INT QUIT TERM

step_line 1 "a few questions"
welcome || die "cancelled."
get_user
get_ssh_pass
get_progs
ask_closed_source
get_vm_kind
plan
summary || die "cancelled."

step_line 2 "installing"
: > "$WORK/failed"
{ install_all 3>&1 1>>"$LOG" 2>&1 </dev/null; } | wt --title "Installing" --gauge "Starting...\n\n " 12 74 0
unset ssh_pass
configure_sudo
[ -n "${home:-}" ] || home=$(getent passwd "$name" | cut -d: -f6)

step_line 3 "done"
mapfile -t failed < <(sort -u "$WORK/failed")
if grep -qx "system update" "$WORK/failed"; then
	msg="The system update failed, so nothing else was installed (installing onto a half-updated system can break it).\n\nWhy is in $LOG (often a mirror that's down, or a package conflict: run  sudo pacman -Syu  to see it). Fix that, then run svs again."
	if (( yes )); then clear; printf '%b\n' "$msg"; else wt --title "Stopped" --msgbox "$msg" 13 76; clear; fi
	exit 1
fi
if (( ${#failed[@]} )); then
	result="Done, but these didn't install:\n\n$(printf '  %s\\n' "${failed[@]}")\nWhy is in $LOG. Install them later with: yay -S NAME"
	height=$(( 14 + ${#failed[@]} ))
else
	result="Everything installed."
	height=12
fi
# the public key, to paste into GitHub (Settings, SSH and GPG keys)
pub=$home/.ssh/id_ed25519.pub
if [ -f "$pub" ]; then
	result+="\n\nYour SSH key is ~/.ssh/id_ed25519.\nFor GitHub, paste its public key (cat ~/.ssh/id_ed25519.pub):\n\n$(cat "$pub")\n\nFingerprint: $(ssh-keygen -lf "$pub" | cut -d' ' -f2)"
	height=$(( height + 9 ))
fi
# scrolling text takes the keys (Enter wouldn't press "Reboot now"): only when it doesn't fit the screen
rows=$(tput lines 2>/dev/null || echo 24) scroll=()
(( height > rows - 2 )) && { height=$(( rows - 2 )); scroll=(--scrolltext); }
if (( autologin )); then after="After a reboot you go straight into your desktop as '$name', no login needed."
else after="After a reboot, log in as '$name' at the login screen, as before."; fi
if (( yes )); then
	clear
	printf '%b\n\n%s\n' "$result" "$after"
elif wt --title "All done!" "${scroll[@]}" --yes-button "Reboot now" --no-button "Later" --yesno \
	"$result\n\n$after\n\n-Sekigetsu" "$height" 78; then
	# what the install left running as you (gpg agents from yay, helpers from update…) is in this login's session,
	# and the shutdown hangs on it behind a black screen: everything of yours stopped first (a login of yours on
	# this tty too, so its hangup mustn't stop svs before the reboot)
	clear
	trap '' HUP
	pkill -TERM -u "$name"; sleep 2; pkill -KILL -u "$name"
	rm -rf "$WORK"
	exec reboot
else
	clear
fi
