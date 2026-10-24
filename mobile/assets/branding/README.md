# Branding assets

`fb200-studio-icon.png` is the 1024 × 1024 opaque master for the app's
amplifier-knob launcher icon, generated with the built-in image_gen tool.
The full prompt is in `fb200-studio-icon-prompt.txt`. It uses the existing
StudioTheme graphite and orange palette.

The launcher resources are installed in Android's five `res/mipmap-*`
directories, iOS's `AppIcon.appiconset`, and `web/icons` plus `web/favicon.png`.
The existing Android manifest, Xcode asset catalog and web manifest already
reference these filenames. These are platform launcher resources; they do not
need a Flutter `pubspec.yaml` asset entry.

On Android 8+ the launcher uses the adaptive icon in
`res/mipmap-anydpi-v26/ic_launcher.xml`: a solid `ic_launcher_background`
color, the knob as `ic_launcher_foreground.png` (outer ring at 64 dp of the
108 dp canvas), and a flat `ic_launcher_monochrome.png` for themed icons.
`mobile/tool/make_launcher_icons.py` regenerates both layers from the master.
The legacy `ic_launcher.png` files remain for older launchers.

`tone3000.png` is the unmodified primary logo from TONE3000's official
[logo package](https://www.tone3000.com/TONE3000%20Logos.zip), linked in the
[API design requirements](https://www.tone3000.com/api#design-requirements),
retrieved 2026-10-18. It is a TONE3000 brand asset, not an MIT-licensed logo
created by this project. Use it to identify the TONE3000 integration. This
experimental integration does not claim an approved commercial partnership.
