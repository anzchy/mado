import plistlib, json, os, sys
p=os.path.expanduser('~/Library/Containers/io.github.anzchy.mado/Data/Library/Preferences/io.github.anzchy.mado.plist')
d=plistlib.load(open(p,'rb')).get('displayPreferences.v1')
print(json.loads(d) if d else None)
