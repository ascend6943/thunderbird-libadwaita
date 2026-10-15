#!/usr/bin/env bash
#
# thunderbird-libadwaita - installer
# https://github.com/ascend6943/thunderbird-libadwaita
#
# Makes Thunderbird look like a GTK4/libadwaita app on GNOME by installing:
#
#   1. thunderbird-gnome-theme -> Adwaita CSS for Thunderbird's own UI
#                                  (into <profile>/chrome, via its official installer)
#   2. adw-gtk3                 -> the libadwaita theme ported to GTK3, placed where
#                                  the app can actually find it (native or Flatpak)
#   3. GSettings                -> points the app at adw-gtk3 and copies your desktop's
#                                  cursor/icons/font/window-button layout into it
#   4. fix stylesheets          -> small patches for two things the theme gets wrong on
#                                  current Thunderbird: icons missing from the composer
#                                  (its CSP blocks the theme's data: URIs) and icons the
#                                  theme references but does not ship
#
set -euo pipefail

# ------------------------------------------------------------------ config ---
GNOME_THEME_REPO="https://github.com/rafaelmardojai/thunderbird-gnome-theme"
ADW_GTK3_API="https://api.github.com/repos/lassekongo83/adw-gtk3/releases/latest"
ADW_GTK3_FALLBACK="https://github.com/lassekongo83/adw-gtk3/releases/download/v6.5/adw-gtk3v6.5.tar.xz"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/thunderbird-libadwaita"
STATE_FILE="$STATE_DIR/state"

# The fix stylesheets live next to this script in the repo; if the script was run
# on its own (not from a checkout) they are fetched from the repository instead.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIX_FILES=(icons-csp-fix.css missing-icons-fix.css)
FIX_RAW_BASE="https://raw.githubusercontent.com/ascend6943/thunderbird-libadwaita/main"

# --------------------------------------------------------------------- cli ---
PROFILE="" YES=0 DRY=0 NO_RESTART=0 NO_SYSTEM_THEME=0
TMP_WORK=""

usage() {
	cat <<'EOF'
Usage: ./install.sh [options]

Options:
  -p, --profile NAME     Install into one profile only (default: every profile found)
  -y, --yes              Answer yes to prompts (e.g. the system GTK3 theme change)
      --no-system-theme  (native installs) Don't set the system GTK3 theme to adw-gtk3
      --no-restart       Don't restart Thunderbird when finished
      --dry-run          Show what would happen, change nothing
  -h, --help             Show this help
EOF
}

# --------------------------------------------------------------- helpers -----
log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "${TMP_WORK}" ] && rm -rf "$TMP_WORK"; return 0; }
trap cleanup EXIT

while [ $# -gt 0 ]; do
	case "$1" in
		-p|--profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
		-y|--yes)     YES=1; shift ;;
		--no-system-theme) NO_SYSTEM_THEME=1; shift ;;
		--no-restart) NO_RESTART=1; shift ;;
		--dry-run)    DRY=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		*)            usage >&2; die "unknown option: $1" ;;
	esac
done

# ------------------------------------------------------------- detection -----
# Entries look like "flatpak:org.mozilla.thunderbird_esr" or "native:/home/.../.thunderbird"
INSTALLS=()

detect_installs() {
	if command -v flatpak >/dev/null 2>&1; then
		local app
		while IFS= read -r app; do
			[ -n "$app" ] && INSTALLS+=("flatpak:$app")
		done < <(flatpak list --app --columns=application 2>/dev/null \
			| grep -E '^org\.mozilla\.thunderbird(_esr)?$' || true)
	fi
	if [ -f "$HOME/.thunderbird/profiles.ini" ]; then
		INSTALLS+=("native:$HOME/.thunderbird")
	fi
	local s
	for s in common current; do
		if [ -f "$HOME/snap/thunderbird/$s/.thunderbird/profiles.ini" ]; then
			INSTALLS+=("snap:$HOME/snap/thunderbird/$s/.thunderbird")
			break
		fi
	done
}

# Where Thunderbird keeps its profile files for a given install.
tb_dir() {
	case "$1" in
		flatpak) printf '%s/.var/app/%s/.thunderbird' "$HOME" "$2" ;;
		*)       printf '%s' "$2" ;;
	esac
}

# Where GTK3 looks for themes for a given install (empty = unsupported).
gtk_theme_dir() {
	case "$1" in
		flatpak) printf '%s/.var/app/%s/data/themes' "$HOME" "$2" ;;
		native)  printf '%s/.local/share/themes' "$HOME" ;;
		snap)    printf '' ;;  # snap confinement hides host theme dirs
	esac
}

# ------------------------------------------------------------- step 1: CSS ---
install_css() {  # $1 = kind, $2 = tb profile dir
	local kind=$1 tbdir=$2
	if [ "$DRY" -eq 1 ]; then
		info "[dry-run] would install thunderbird-gnome-theme into: $tbdir (profiles: ${PROFILE:-all})"
		return 0
	fi
	git clone --depth 1 "$GNOME_THEME_REPO" "$TMP_WORK/thunderbird-gnome-theme" >/dev/null 2>&1 \
		|| die "failed to clone $GNOME_THEME_REPO"
	local args=(-f "$tbdir")
	[ -n "$PROFILE" ] && args+=(-p "$PROFILE")
	bash "$TMP_WORK/thunderbird-gnome-theme/scripts/install.sh" "${args[@]}" \
		|| die "thunderbird-gnome-theme install failed for $tbdir"
	info "Adwaita CSS installed into $tbdir ${PROFILE:+(profile: $PROFILE)}"
}

# --------------------------------------------------------- step 1b: fixes ----
# Both fix stylesheets patch things the theme gets wrong on current Thunderbird:
#
#   icons-csp-fix.css    The theme replaces Thunderbird's icons with GNOME icons
#                        embedded as `url("data:image/svg+xml,...")`. The composer
#                        and the standalone message window ship a
#                        Content-Security-Policy of `img-src chrome: moz-icon:`,
#                        which blocks data: images - so every toolbar button whose
#                        icon the theme swapped out (Send, Encrypt, Spelling, Save,
#                        Contacts, Attach, ...) renders empty there. This file
#                        points those icons back at Thunderbird's own chrome://
#                        icons inside those two windows only.
#
#   missing-icons-fix.css
#                        The theme references five SVG files it does not ship
#                        (theme/icons/*.svg), so the tab close button, checkboxes,
#                        radio buttons and legacy tree folders lose their glyph.
#                        This file re-points them at the theme's own icon
#                        variables.
fix_source() {  # $1 = file name -> prints a local path, or fails
	local name=$1
	if [ -f "$SCRIPT_DIR/$name" ]; then
		printf '%s' "$SCRIPT_DIR/$name"
		return 0
	fi
	if [ -n "${TMP_WORK:-}" ] && curl -fsSL -o "$TMP_WORK/$name" "$FIX_RAW_BASE/$name" 2>/dev/null; then
		printf '%s' "$TMP_WORK/$name"
		return 0
	fi
	return 1
}

install_fixes() {  # $1 = tb folder (e.g. ~/.var/app/<id>/.thunderbird)
	local tbdir=$1 name src p dirs=()
	if [ "$DRY" -eq 1 ]; then
		info "[dry-run] would install ${FIX_FILES[*]} into: $tbdir (profiles: ${PROFILE:-all})"
		return 0
	fi

	if [ -n "$PROFILE" ]; then
		dirs=("$tbdir/$PROFILE")
	else
		for p in "$tbdir"/*/; do
			[ -d "$p" ] && dirs+=("${p%/}")
		done
	fi

	local found=0
	for p in "${dirs[@]}"; do
		# userChrome.css is created by the theme installer; if it is missing the
		# CSS part has not run for this profile, so there is nothing to hook into.
		[ -f "$p/chrome/userChrome.css" ] || continue
		for name in "${FIX_FILES[@]}"; do
			src=$(fix_source "$name") \
				|| { warn "could not obtain $name - its icons will stay missing"; continue; }
			cp "$src" "$p/chrome/$name"
			grep -qF "@import \"$name\";" "$p/chrome/userChrome.css" \
				|| printf '@import "%s";\n' "$name" >> "$p/chrome/userChrome.css"
			found=1
		done
	done
	[ "$found" -eq 1 ] && info "fix stylesheets installed into $tbdir ${PROFILE:+(profile: $PROFILE)}"
	return 0
}

# ------------------------------------------------------ step 2: adw-gtk3 -----
download_adw() {
	TMP_WORK=$(mktemp -d)
	local url
	url=$(curl -fsSL "$ADW_GTK3_API" 2>/dev/null \
		| grep -o '"browser_download_url": *"[^"]*\.tar\.xz"' \
		| head -1 | cut -d'"' -f4) || url=""
	[ -z "$url" ] && url="$ADW_GTK3_FALLBACK"
	log "Downloading adw-gtk3 ($(basename "$url"))"
	curl -fsSL -o "$TMP_WORK/adw-gtk3.tar.xz" "$url" \
		|| die "failed to download adw-gtk3 (from $url)"
	tar -xf "$TMP_WORK/adw-gtk3.tar.xz" -C "$TMP_WORK" \
		|| die "failed to extract adw-gtk3"
	[ -d "$TMP_WORK/adw-gtk3" ] && [ -d "$TMP_WORK/adw-gtk3-dark" ] \
		|| die "unexpected adw-gtk3 archive layout"
}

place_adw() {  # $1 = kind, $2 = app id / path
	local kind=$1 val=$2 dir
	dir=$(gtk_theme_dir "$kind" "$val")
	if [ -z "$dir" ]; then
		warn "snap install: skipping the GTK theme part (snap confinement hides host theme dirs); the CSS part still applies"
		return 0
	fi
	if [ "$DRY" -eq 1 ]; then
		info "[dry-run] would install adw-gtk3 + adw-gtk3-dark into: $dir"
		return 0
	fi
	mkdir -p "$dir"
	rm -rf "$dir/adw-gtk3" "$dir/adw-gtk3-dark"
	cp -R "$TMP_WORK/adw-gtk3" "$TMP_WORK/adw-gtk3-dark" "$dir/"
	info "adw-gtk3 installed into $dir"
}

# ------------------------------------------------------- step 3: GSettings ---
# Reads a value from the *host* GSettings and prints it as a serialized value.
host_get() { gsettings get "$@" 2>/dev/null || printf "''"; }

confirm_system_theme() {
	[ "$NO_SYSTEM_THEME" -eq 1 ] && return 1
	[ "$YES" -eq 1 ] && return 0
	if [ -t 0 ]; then
		printf '    Set the SYSTEM GTK3 theme to adw-gtk3? This affects all legacy GTK3 apps. [y/N] '
		local a=""
		read -r a || a=""
		case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
	fi
	warn "not a terminal: skipping the system-wide GTK3 theme change (re-run with -y to apply)"
	return 1
}

save_state() {
	mkdir -p "$STATE_DIR"
	[ -f "$STATE_FILE" ] && return 0
	printf 'gtk-theme=%s\n' "$(host_get org.gnome.desktop.interface gtk-theme)" > "$STATE_FILE"
}

apply_settings() {  # $1 = kind, $2 = app id / path
	local kind=$1 val=$2

	if ! command -v gsettings >/dev/null 2>&1; then
		warn "gsettings not found; skipping the GTK theme assignment"
		return 0
	fi

	if [ "$DRY" -eq 1 ]; then
		if [ "$kind" = flatpak ]; then
			info "[dry-run] would set gtk-theme=adw-gtk3 + mirror cursor/icons/font/buttons into the Flatpak's isolated GSettings ($val)"
		elif [ "$kind" = native ]; then
			info "[dry-run] would set the system GTK3 theme to adw-gtk3 (with confirmation)"
		else
			info "[dry-run] snap: nothing to configure"
		fi
		return 0
	fi

	case "$kind" in
	flatpak)
		# Flatpaks read their own isolated GSettings (keyfile backend), not the
		# host's - so this only affects Thunderbird.
		local G=(flatpak run --command=gsettings "$val")
		"${G[@]}" set org.gnome.desktop.interface gtk-theme adw-gtk3 2>&1 \
			|| warn "could not set gtk-theme inside the sandbox"
		# Mirror the desktop's look so the app matches the rest of the session.
		"${G[@]}" set org.gnome.desktop.interface cursor-theme \
			"$(host_get org.gnome.desktop.interface cursor-theme)" 2>/dev/null || true
		"${G[@]}" set org.gnome.desktop.interface icon-theme \
			"$(host_get org.gnome.desktop.interface icon-theme)" 2>/dev/null || true
		"${G[@]}" set org.gnome.desktop.interface font-name \
			"$(host_get org.gnome.desktop.interface font-name)" 2>/dev/null || true
		"${G[@]}" set org.gnome.desktop.wm.preferences button-layout \
			"$(host_get org.gnome.desktop.wm.preferences button-layout)" 2>/dev/null || true
		info "gtk-theme=adw-gtk3 set inside the Flatpak (system settings untouched)"
		;;
	native)
		# A native GTK3 app reads the system GSettings, so the only way to give
		# it adw-gtk3 is to set it system-wide (GTK4/libadwaita apps ignore it).
		if confirm_system_theme; then
			save_state
			gsettings set org.gnome.desktop.interface gtk-theme adw-gtk3
			info "system GTK3 theme set to adw-gtk3 (previous value saved for uninstall)"
		fi
		;;
	snap)
		info "snap: nothing to configure (CSS part only)"
		;;
	esac
}

# ------------------------------------------------------------ step 4: start ---
restart_thunderbird() {
	if [ "$NO_RESTART" -eq 1 ]; then
		info "--no-restart given: restart Thunderbird manually to apply everything"
		return 0
	fi
	if [ "$DRY" -eq 1 ]; then
		info "[dry-run] would restart Thunderbird if it is running"
		return 0
	fi

	local entry kind val killed=()
	for entry in "${INSTALLS[@]}"; do
		kind=${entry%%:*} val=${entry#*:}
		case "$kind" in
		flatpak)
			if flatpak ps --columns=application 2>/dev/null | grep -qx "$val"; then
				flatpak kill "$val" 2>/dev/null || true
				killed+=("flatpak:$val")
			fi ;;
		native)
			if pgrep -x thunderbird >/dev/null 2>&1 || pgrep -x thunderbird-bin >/dev/null 2>&1; then
				pkill -x thunderbird 2>/dev/null || true
				pkill -x thunderbird-bin 2>/dev/null || true
				killed+=("native:thunderbird")
			fi ;;
		snap)
			if pgrep -f '/thunderbird/' >/dev/null 2>&1; then
				pkill -f '/thunderbird/' 2>/dev/null || true
				killed+=("snap:thunderbird")
			fi ;;
		esac
	done

	if [ "${#killed[@]}" -eq 0 ]; then
		info "Thunderbird is not running; start it normally"
		return 0
	fi

	info "Restarting Thunderbird..."
	sleep 3
	for entry in "${killed[@]}"; do
		kind=${entry%%:*} val=${entry#*:}
		case "$kind" in
		flatpak) nohup flatpak run "$val" >/dev/null 2>&1 </dev/null & ;;
		native)
			if command -v thunderbird >/dev/null 2>&1; then
				nohup thunderbird >/dev/null 2>&1 </dev/null &
			else
				warn "thunderbird not in PATH; start it yourself"
			fi ;;
		snap) nohup snap run thunderbird >/dev/null 2>&1 </dev/null & ;;
		esac
	done
}

# ------------------------------------------------------------------ main -----
main() {
	if [ "$DRY" -eq 0 ]; then
		local c
		for c in git curl tar; do
			command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c"
		done
	fi

	detect_installs
	[ "${#INSTALLS[@]}" -gt 0 ] || die "no Thunderbird installation found (Flatpak, ~/.thunderbird, or snap)"

	log "Thunderbird installation(s) found:"
	local entry kind val
	for entry in "${INSTALLS[@]}"; do
		kind=${entry%%:*} val=${entry#*:}
		info "$kind: $(tb_dir "$kind" "$val")"
	done

	[ "$DRY" -eq 0 ] && download_adw

	for entry in "${INSTALLS[@]}"; do
		kind=${entry%%:*} val=${entry#*:}
		local tbdir
		tbdir=$(tb_dir "$kind" "$val")
		if [ ! -d "$tbdir" ]; then
			warn "$kind install has no profile dir yet ($tbdir) - start Thunderbird once, then re-run"
			continue
		fi
		log "Configuring [$kind] $val"
		install_css "$kind" "$tbdir"
		install_fixes "$tbdir"
		place_adw "$kind" "$val"
		apply_settings "$kind" "$val"
	done

	restart_thunderbird

	if [ "$DRY" -eq 1 ]; then
		log "Dry run complete - nothing was changed."
	else
		log "Done. Thunderbird now has the GNOME/libadwaita look."
		info "Undo anytime with: ./uninstall.sh"
	fi
}

main
