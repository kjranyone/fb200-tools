# Branding assets

`fb200-studio-icon.png` is the 1024 × 1024 opaque master for the app's
amplifier-knob launcher icon, generated with the built-in image_gen tool.
The full prompt is in `fb200-studio-icon-prompt.txt`. It uses the existing
StudioTheme graphite and orange palette.

The launcher resources are installed in Android's five `res/mipmap-*`
directories, iOS's `AppIcon.appiconset`, and `web/icons` plus `web/favicon.png`.
The existing Android manifest, Xcode asset catalog and web manifest already
reference these filenames. These are platform launcher resources; they do not
need a Flutter `pubspec.yaml` asset entry. Android currently uses legacy PNG
launcher icons, without adaptive or themed icon layers.

`tone3000.png` is the unmodified primary logo from TONE3000's official
[logo package](https://www.tone3000.com/TONE3000%20Logos.zip), linked in the
[API design requirements](https://www.tone3000.com/api#design-requirements),
retrieved 2026-10-18. It is a TONE3000 brand asset, not an MIT-licensed logo
created by this project. Use it to identify the TONE3000 integration. This
experimental integration does not claim an approved commercial partnership.
