#!/usr/bin/env python
"""Subscribe to VM stdout, trigger a UI tap, and capture the exception printout."""
import json
import subprocess
import sys
import time
import urllib.request

BASE = 'http://127.0.0.1:43499/Ng81zdvsX0E=/'
ADB = r'C:/Users/sherl/AppData/Local/Temp/next-transfer-toolchain/android-sdk/platform-tools/adb.exe'

def rpc(method, params=None, req_id='1'):
    body = json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params or {}, 'id': req_id}).encode()
    req = urllib.request.Request(BASE, data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())

# Find the main isolate
vm = rpc('getVM')
isolate_id = None
for iso in vm['result']['isolates']:
    if iso['name'] == 'main':
        isolate_id = iso['id']
        break
print('main isolate:', isolate_id)

# Subscribe to stdout
stream = rpc('streamListen', {'isolateId': isolate_id, 'streamId': 'Stdout'})
print('streamListen:', stream.get('result', stream.get('error')))

# Now tap Aug 6 to reproduce
subprocess.run([ADB, 'shell', 'input', 'tap', '390', '380'], capture_output=True)
time.sleep(4)

# Poll for events via a second WS-like request: use getStream? Actually events
# need a websocket; instead we re-capture logcat which flutter debugPrint uses.
subprocess.run([ADB, 'logcat', '-d'], capture_output=True)
