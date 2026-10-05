#!/usr/bin/env python3
"""Compile the standard macOS AppIcon asset when full Xcode is available."""
import json, pathlib, shutil, subprocess, sys, tempfile
app = pathlib.Path(sys.argv[1])
iconset = pathlib.Path(sys.argv[2])
actool = pathlib.Path('/Applications/Xcode.app/Contents/Developer/usr/bin/actool')
if not actool.exists():
    print('Xcode actool unavailable; retaining ICNS fallback')
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix='ResetCardBar-assets-') as tmp:
    catalog = pathlib.Path(tmp) / 'Assets.xcassets'
    icons = catalog / 'AppIcon.appiconset'
    icons.mkdir(parents=True)
    info = {'info': {'author': 'xcode', 'version': 1}}
    (catalog / 'Contents.json').write_text(json.dumps(info))
    images = []
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            shutil.copyfile(iconset / name, icons / name)
            images.append({'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': name})
    (icons / 'Contents.json').write_text(json.dumps(dict(info, images=images)))
    subprocess.run([str(actool), str(catalog), '--compile', str(app / 'Contents/Resources'), '--platform', 'macosx', '--minimum-deployment-target', '13.0', '--app-icon', 'AppIcon', '--output-format', 'human-readable-text', '--output-partial-info-plist', str(pathlib.Path(tmp)/'icon-info.plist')], check=True)
