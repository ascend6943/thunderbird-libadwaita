# thunderbird-libadwaita

**Make Thunderbird look like a GTK4/libadwaita app on GNOME.**
<img width="2529" height="1402" alt="image" src="https://github.com/user-attachments/assets/b8f9168d-5891-49ac-8bef-ba87cdf9b72a" />


Adwaita headerbar with rounded corners and in-headerbar window buttons, `#3584e4` blue
accent, pill-shaped search entries, card-style message list, popover menus, and matching
native dialogs — in light *and* dark — for Thunderbird 115+ on Linux.

> Tested on Ubuntu 26.04 LTS · GNOME 50.1 · Thunderbird 153.4.0esr (Flatpak)

---

## How it works

Thunderbird is a GTK app, but almost everything you see is drawn by Gecko with its own
CSS, while GTK draws the "native" bits (window decorations and buttons, some menus and
dialogs, fonts, cursors, icon theme). To look like a real libadwaita app, all three
layers have to agree — so this project sets up those three layers, plus two small
stylesheets that patch parts of the theme which are broken on current Thunderbird:

### 1. `thunderbird-gnome-theme` — the UI skin (CSS)

[Rafael Mardojai's GNOME theme](https://github.com/rafaelmardojai/thunderbird-gnome-theme)
is cloned and installed into `<profile>/chrome/` using its official installer. It restyles
Thunderbird's headerbar, tab bar, toolbars, message list, buttons, entries, popups and
dialogs with the Adwaita palette, and auto-switches light/dark via `prefers-color-scheme`.

Two preferences are added to the profile's `user.js`:

- `toolkit.legacyUserProfileCustomizations.stylesheets` = true — makes Thunderbird load
  the CSS from `chrome/`
- `svg.context-properties.content.enabled` = true — lets the theme recolor icons

### 2. `adw-gtk3` — libadwaita for the GTK3 layer

libadwaita is GTK4-only, so GTK3 apps (including Thunderbird's native surfaces) can't use
it. [adw-gtk3](https://github.com/lassekongo83/adw-gtk3) is the libadwaita theme ported
to GTK3, and it's what gives the native parts the same look.

The tricky part is *where* the app can see it:

| Thunderbird install | Theme goes here |
|---|---|
| Native (`.deb` / `.rpm` / tarball) | `~/.local/share/themes/` |
| Flatpak | `~/.var/app/<app-id>/data/themes/` (the sandbox's `XDG_DATA_HOME`) |
| Snap | *skipped* — snap confinement hides host theme dirs |

Flatpak apps cannot read `~/.themes` or `~/.local/share/themes` on the host, which is
why the Flatpak gets its own copy.

### 3. GSettings — pointing the app at adw-gtk3

- **Flatpak:** the value is written into the app's *isolated* GSettings store (Flatpak
  apps get their own, separate from the system), so **only Thunderbird changes** —
  your system theme stays exactly as it is. The installer also copies your desktop's
  cursor theme, icon theme, font and window-button layout into the sandbox so
  Thunderbird matches the rest of your session.
- **Native:** a native GTK3 app reads system settings, so the only way to give it
  adw-gtk3 is setting the *system* GTK3 theme (`org.gnome.desktop.interface gtk-theme`).
  You'll be asked to confirm this. All legacy GTK3 apps then get the libadwaita look
  too (GTK4/libadwaita apps ignore GTK themes, so they are unaffected). The previous
  value is saved and restored by `uninstall.sh`.

### 4. `icons-csp-fix.css` — bringing back the composer's icons

The GNOME theme replaces Thunderbird's icons with GNOME symbolic icons embedded in its CSS
as `url("data:image/svg+xml,...")` values. Thunderbird ships a Content-Security-Policy with
every window, and two of them refuse to load `data:` images:

| Window | `img-src` in its CSP | Theme icons |
|---|---|---|
| Main window (`messenger.xhtml`) | `chrome: data: moz-icon: …` | ✅ load fine |
| **Message composer** (`messengercompose.xhtml`) | `chrome: moz-icon:` | ❌ blocked by CSP |
| **Single-message window** (`messageWindow.xhtml`) | `chrome: moz-icon:` | ❌ blocked by CSP |

So in the composer, every button whose icon the theme swapped out — Send, Encrypt,
Spelling, Save, Contacts, Attach … — showed its label but no icon. (This is the theme's
upstream
[issue #18](https://github.com/rafaelmardojai/thunderbird-gnome-theme/issues/18) /
[#22](https://github.com/rafaelmardojai/thunderbird-gnome-theme/issues/22).)

`icons-csp-fix.css` is a small stylesheet this project installs into `<profile>/chrome/`
and imports from `userChrome.css`. Inside those two windows only, it points the affected
icon variables back at Thunderbird's own `chrome://` icons — which the CSP *does* allow —
and restores the `fill` + `stroke` paint context those icons need. Every other window
keeps the theme's GNOME icons.

### 5. `missing-icons-fix.css` — icons the theme references but doesn't ship

The theme's CSS points at loose SVG files under `theme/icons/`:

```css
theme/parts/tabsbar.css   url("../icons/window-close-symbolic.svg")
theme/parts/controls.css  url("../icons/select-symbolic.svg")
theme/parts/controls.css  url("../icons/bullet-symbolic.svg")
theme/parts/icons.css     url("../icons/folder-symbolic.svg")
theme/parts/icons.css     url("../icons/preferences-system-time-symbolic.svg")
```

None of those files exist — the theme *generates* its icons into
`theme/icons/icons.css` as `--gnome-icon-*-symbolic` data: URIs, and the only loose SVGs
it still ships are in `theme/icons/custom/`. A `url()` that fails to load paints nothing,
so each of those controls lost its glyph entirely:

| Broken | Symptom |
|---|---|
| `.tab-close-button` | no × on the tabs — the theme's own `content: url(...)` also throws away the child image Thunderbird 153 would have shown |
| `.checkbox-check[checked]` | checked checkboxes are a plain blue square, with no ✓ |
| `.radio-check[selected]` | selected radio buttons are a plain blue circle, with no dot |
| `treechildren::-moz-tree-image(...)` | no folder/history icons in legacy tree dialogs (Subscribe, Search…) |

`missing-icons-fix.css` re-points each one at the theme's own icon variable, so the result
is what the theme intended in the first place.

Finally Thunderbird is restarted so everything takes effect.

---

## Which systems it works on

| | Supported |
|---|---|
| **OS** | **Linux only** (not Windows/macOS) |
| **Desktop** | GNOME is the target. Other GTK desktops (Cinnamon, Xfce, MATE, …) work for the CSS skin; menus/decorations follow that DE |
| **Session** | Wayland ✅ and X11 ✅ |
| **Thunderbird** | 115+ (Supernova) and newer — tested up to 153.4.0esr. Thunderbird **< 115 is not supported** |
| **Packaging** | **Flatpak** ✅ full (`org.mozilla.thunderbird`, `org.mozilla.thunderbird_esr`) · **Native** ✅ full (`.deb`/`.rpm`/tarball, `~/.thunderbird`) · **Snap** ⚠️ CSS skin only (confinement blocks GTK themes) |
| **Appearance** | Light and dark, following Thunderbird/system |
| **Distro** | Any (needs `bash`, `git`, `curl`, `tar`; GNOME for best results) |
| **Tested on** | Ubuntu 26.04 LTS, GNOME 50.1, Thunderbird 153.4.0esr Flatpak |

It works alongside your current desktop theme: the Flatpak path touches nothing outside
Thunderbird's own directories, and the native path only changes the GTK3 theme.

---

## Install

```bash
git clone https://github.com/ascend6943/thunderbird-libadwaita.git
cd thunderbird-libadwaita
./install.sh
```

The installer finds every Thunderbird it can (Flatpak, native, snap), installs into
**all** profiles, and restarts Thunderbird when it's done.

### Options

```
./install.sh [options]

  -p, --profile NAME     Install into one profile only (default: all found)
  -y, --yes              Answer yes to prompts (e.g. the system GTK3 theme change)
      --no-system-theme  (native) Don't set the system GTK3 theme to adw-gtk3
      --no-restart       Don't restart Thunderbird when finished
      --dry-run          Show what would happen, change nothing
  -h, --help             Show this help
```

Examples:

```bash
./install.sh --dry-run                # preview, change nothing
./install.sh -y                       # unattended, yes to the system theme prompt
./install.sh -p ab12cd34.default      # only one profile
```

### Updating

Re-run `./install.sh` — it re-clones the latest `thunderbird-gnome-theme` and refreshes
adw-gtk3. Worth doing after Thunderbird updates, since the CSS tracks current releases.

---

## Uninstall

```bash
./uninstall.sh
```

Removes the theme from every profile's `chrome/` (keeping any CSS files you added
yourself), removes the fix stylesheets (`icons-csp-fix.css`, `missing-icons-fix.css`) and
their import lines, removes the two prefs the theme added, deletes adw-gtk3 from the
locations this project installed it to, and restores/resets the GSettings values —
including restoring your previous system GTK3 theme on native installs.

---

## Manual installation

If you'd rather do it by hand (this is exactly what the script automates), for a
**Flatpak** install:

```bash
# 1. UI skin
git clone https://github.com/rafaelmardojai/thunderbird-gnome-theme
TB=~/.var/app/org.mozilla.thunderbird_esr/.thunderbird   # or ...thunderbird
./thunderbird-gnome-theme/scripts/install.sh -f "$TB"

# 2. GTK3 libadwaita theme, inside the sandbox's view of XDG_DATA_HOME
mkdir -p ~/.var/app/org.mozilla.thunderbird_esr/data/themes
curl -LO https://github.com/lassekongo83/adw-gtk3/releases/download/v6.5/adw-gtk3v6.5.tar.xz
tar -xf adw-gtk3v6.5.tar.xz -C ~/.var/app/org.mozilla.thunderbird_esr/data/themes

# 3. Point the sandbox's isolated GSettings at it (host settings untouched)
flatpak run --command=gsettings org.mozilla.thunderbird_esr \
  set org.gnome.desktop.interface gtk-theme adw-gtk3

# 4. Fix stylesheets (composer icons blocked by CSP; icons the theme doesn't ship)
PROFILE="$TB/$(grep -m1 '^Path=' "$TB/profiles.ini" | cut -d= -f2)/chrome"
for f in icons-csp-fix.css missing-icons-fix.css; do
  cp "$f" "$PROFILE/"
  echo "@import \"$f\";" >> "$PROFILE/userChrome.css"
done

# 5. Restart Thunderbird
```

For a **native** install, use `~/.thunderbird` as `$TB` in step 1, install adw-gtk3 into
`~/.local/share/themes/`, and set the theme with `gsettings set org.gnome.desktop.interface
gtk-theme adw-gtk3` (this is the system-wide one — see above).

---

## Customization

- **Accent color** — edit the `#3584e4` values in
  `<profile>/chrome/thunderbird-gnome-theme/theme/colors/{light,dark}.css`.
  GNOME palette: green `#33d17a`, orange `#ff7800`, red `#e01b24`, purple `#9141ac`.
- **Optional features** — in Thunderbird's Config Editor, create these boolean prefs:
  - `gnomeTheme.hideTabbar` — hide the tab bar with the menu bar
  - `gnomeTheme.normalWidthTabs` — normal-width (non-elastic) tabs
  - `gnomeTheme.activeTabContrast` — more contrast on the active tab
- **Dark mode** — handled automatically via `prefers-color-scheme`; the `adw-gtk3-dark`
  GTK theme is installed alongside the light one.
- **Your own CSS** — put it in `<profile>/chrome/customChrome.css`; the theme imports it
  and updates won't touch it.

---

## Troubleshooting

**Nothing changed after install** — the CSS only loads at startup; restart Thunderbird
fully (the script does this).

**Menus/dialogs don't look Adwaita (Flatpak)** — verify the sandbox sees the theme:

```bash
flatpak run --command=gsettings org.mozilla.thunderbird_esr get org.gnome.desktop.interface gtk-theme
flatpak run --command=sh org.mozilla.thunderbird_esr -c 'ls $XDG_DATA_HOME/themes'
```

Both should say `adw-gtk3`. If the key is missing, re-run `./install.sh`.

**Icons render black** — `svg.context-properties.content.enabled` isn't set; check the
profile's `user.js` and the Config Editor.

**The composer shows labels but no icons** — `icons-csp-fix.css` is missing from
`<profile>/chrome/` (or isn't imported). Re-run `./install.sh`, which reinstalls it; see
[step 4](#4-icons-csp-fixcss--bringing-back-the-composers-icons) for why it's needed.

**No × on the tabs, or checkboxes/radios lost their glyph** — `missing-icons-fix.css` is
missing from `<profile>/chrome/` (or isn't imported). Re-run `./install.sh`; see
[step 5](#5-missing-icons-fixcss--icons-the-theme-references-but-doesnt-ship) for why it's
needed.

**After a Thunderbird update something looks off** — the CSS tracks Thunderbird's UI
internals; re-run `./install.sh` to pull the latest theme.

**Wrong profile** — list what's installed, then target one:

```bash
ls ~/.thunderbird                 # native
ls ~/.var/app/org.mozilla.thunderbird_esr/.thunderbird   # flatpak
./install.sh -p <profile-dir-name>
```

---

## Credits

- [thunderbird-gnome-theme](https://github.com/rafaelmardojai/thunderbird-gnome-theme)
  by Rafael Mardojai CM — the Adwaita UI skin (Unlicense)
- [adw-gtk3](https://github.com/lassekongo83/adw-gtk3) by lassekongo83 — libadwaita for
  GTK3 (LGPL-2.1)

This project just wires those two together for native, Flatpak and snap installs.
Not affiliated with Mozilla or the GNOME Project.

## License

MIT — see [LICENSE](LICENSE).
