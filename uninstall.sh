#!/usr/bin/env bash
#
# thunderbird-libadwaita - uninstaller
# https://github.com/ascend6943/thunderbird-libadwaita
#
# Removes everything install.sh sets up:
#   - the thunderbird-gnome-theme files from every profile's chrome/ dir
#   - the fix stylesheets (and their import lines) from every profile's chrome/ dir
#   - the two prefs the theme adds to the profile's user.js
#   - adw-gtk3 from the theme dirs it was installed into
#   - the GSettings changes (Flatpak: reset; native: restore saved value)
#
set -euo pipefail

FIX_FILES=(icons-csp-fix.css missing-icons-fix.css)
STATE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/thunderbird-libadwaita/state"

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }

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

tb_dir() {
	case "$1" in
		flatpak) printf '%s/.var/app/%s/.thunderbird' "$HOME" "$2" ;;
		*)       printf '%s' "$2" ;;
	esac
}

gtk_theme_dir() {
	case "$1" in
		flatpak) printf '%s/.var/app/%s/data/themes' "$HOME" "$2" ;;
		native)  printf '%s/.local/share/themes' "$HOME" ;;
		snap)    printf '' ;;
	esac
}

# Remove the theme from one profile, keeping anything else the user put in chrome/.
clean_profile() {  # $1 = profile dir
	local pdir=$1
	[ -d "$pdir" ] || return 0

	# Fix stylesheets shipped by this repo (independent of the theme).
	local name removed=0
	for name in "${FIX_FILES[@]}"; do
		[ -f "$pdir/chrome/$name" ] && removed=1
		rm -f "$pdir/chrome/$name"
		if [ -f "$pdir/chrome/userChrome.css" ]; then
			sed -i -e "/@import \"$name\";/d" "$pdir/chrome/userChrome.css"
		fi
	done
	if [ "$removed" -eq 1 ]; then
		info "fix stylesheets removed from $pdir"
	fi

	if [ -d "$pdir/chrome/thunderbird-gnome-theme" ]; then
		rm -rf "$pdir/chrome/thunderbird-gnome-theme"
		local f
		for f in userChrome.css userContent.css; do
			if [ -f "$pdir/chrome/$f" ]; then
				sed -i '/thunderbird-gnome-theme/d' "$pdir/chrome/$f"
				# drop the file if nothing but blank lines are left
				grep -q '[^[:space:]]' "$pdir/chrome/$f" || rm -f "$pdir/chrome/$f"
			fi
		done
		rmdir "$pdir/chrome" 2>/dev/null || true
		info "theme removed from $pdir"
	fi

	if [ -f "$pdir/user.js" ] \
		&& grep -q -E 'legacyUserProfileCustomizations|svg\.context-properties' "$pdir/user.js"; then
		sed -i -e '/user_pref("toolkit.legacyUserProfileCustomizations.stylesheets"/d' \
		       -e '/user_pref("svg\.context-properties\.content\.enabled"/d' "$pdir/user.js"
		info "theme prefs removed from $pdir/user.js"
	fi
}

clean_profiles() {  # $1 = kind, $2 = tb folder
	local tbdir=$2 path
	while IFS= read -r path; do
		[ -n "$path" ] && clean_profile "$tbdir/$path"
	done < <(grep -E '^Path=' "$tbdir/profiles.ini" 2>/dev/null | cut -d= -f2- || true)
}

clean_gtk_theme() {  # $1 = kind, $2 = val
	local dir
	dir=$(gtk_theme_dir "$1" "$2")
	if [ -n "$dir" ]; then
		rm -rf "$dir/adw-gtk3" "$dir/adw-gtk3-dark"
	fi
	return 0
}

reset_settings() {  # $1 = kind, $2 = val
	local kind=$1 val=$2
	command -v gsettings >/dev/null 2>&1 || return 0

	case "$kind" in
	flatpak)
		# The app's GSettings store was empty before install, so a reset
		# returns exactly to the pre-install state.
		local G=(flatpak run --command=gsettings "$val")
		"${G[@]}" reset org.gnome.desktop.interface gtk-theme 2>/dev/null || true
		"${G[@]}" reset org.gnome.desktop.interface cursor-theme 2>/dev/null || true
		"${G[@]}" reset org.gnome.desktop.interface icon-theme 2>/dev/null || true
		"${G[@]}" reset org.gnome.desktop.interface font-name 2>/dev/null || true
		"${G[@]}" reset org.gnome.desktop.wm.preferences button-layout 2>/dev/null || true
		info "GSettings reset inside the Flatpak"
		;;
	native)
		if [ -f "$STATE_FILE" ]; then
			local prev
			prev=$(sed -n 's/^gtk-theme=//p' "$STATE_FILE")
			if [ -n "$prev" ]; then
				gsettings set org.gnome.desktop.interface gtk-theme "$prev" 2>/dev/null \
					|| warn "could not restore the previous GTK theme ($prev)"
				info "system GTK3 theme restored to $prev"
			fi
			rm -f "$STATE_FILE"
		fi
		;;
	esac
}

main() {
	detect_installs
	[ "${#INSTALLS[@]}" -gt 0 ] || { log "No Thunderbird installation found - nothing to do."; exit 0; }

	local entry kind val
	for entry in "${INSTALLS[@]}"; do
		kind=${entry%%:*} val=${entry#*:}
		log "Cleaning [$kind] $val"
		clean_profiles "$kind" "$(tb_dir "$kind" "$val")"
		clean_gtk_theme "$kind" "$val"
		reset_settings "$kind" "$val"
	done

	log "Uninstalled. Restart Thunderbird to see the stock UI again."
	info "Note: this also removes the two prefs the theme added; if you had your own"
	info "userChrome.css setup, re-enable 'toolkit.legacyUserProfileCustomizations.stylesheets'."
}

main
