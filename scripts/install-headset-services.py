#!/usr/bin/env python3
"""Install bundled mapping guard; retire the legacy app only after verified handoff."""
import datetime, json, os, pathlib, plistlib, subprocess
home = pathlib.Path.home()
app = home / 'Applications/PocketDesk.app'
helper = app / 'Contents/Helpers/HeadsetOptionMapping'
support = home / 'Library/Application Support/VoiceDeck/headset'
support.mkdir(parents=True, exist_ok=True)
agents = home / 'Library/LaunchAgents'
agents.mkdir(parents=True, exist_ok=True)
domain = f'gui/{os.getuid()}'
def call(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)
call(str(helper), '--self-test')
# An unplugged headset is allowed: the guard will repair its next connection.
probe = call(str(helper), '--once', check=False)
state = json.loads(probe.stdout)['state']
if state not in ('verified', 'waiting_for_headset'):
    raise RuntimeError('Bundled Option mapping verification failed; legacy services retained')
label = 'dev.voicedeck.headset-option-mapping'
plist = agents / (label + '.plist')
plist.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=[str(helper)], RunAtLoad=True,
    KeepAlive=True, ThrottleInterval=5, ProcessType='Background',
    StandardOutPath=str(support/'option-mapping.log'), StandardErrorPath=str(support/'option-mapping-error.log'))))
call('launchctl', 'bootout', domain+'/'+label, check=False)
call('launchctl', 'bootstrap', domain, str(plist))
call('launchctl', 'print', domain+'/'+label)
backup = support / ('legacy-backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
backup.mkdir()
for old in ('local.cm.HeadsetVoiceControl', 'local.cm.HeadsetOptionMapping'):
    call('launchctl', 'bootout', domain+'/'+old, check=False)
    path = agents / (old+'.plist')
    if path.exists(): path.rename(backup/path.name)
call('pkill', '-x', 'HeadsetVoiceControl', check=False)
# Keep the old signed app recoverable outside Applications.
old_app = home/'Applications/HeadsetVoiceControl.app'
if old_app.exists(): old_app.rename(backup/old_app.name)
# Preserve the former enhancement app's login startup, without restarting after a normal quit.
label = 'dev.voicedeck.app'
plist = agents/(label+'.plist')
plist.write_bytes(plistlib.dumps(dict(Label=label,
    ProgramArguments=[str(app/'Contents/MacOS/VoiceDeck')], RunAtLoad=True,
    KeepAlive=dict(SuccessfulExit=False), ThrottleInterval=15, ProcessType='Interactive',
    StandardOutPath=str(support/'pocketdesk-launch.log'), StandardErrorPath=str(support/'pocketdesk-launch-error.log'))))
call('launchctl', 'bootout', domain+'/'+label, check=False)
call('launchctl', 'bootstrap', domain, str(plist))
print('PocketDesk headset services installed; mapping state:', state)
