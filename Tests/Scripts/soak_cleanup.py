#!/usr/bin/env python3
"""Exercise the production cleanup with an undiscovered, disposable process tree.
No app, defaults, hardware, screenshots, or other users' processes are touched.
"""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

source = (Path(__file__).resolve().parents[2] / 'Scripts/soak.sh').read_text()
cleanup = source[source.index('cleanup() {'):source.index('\ntrap cleanup EXIT')]
for ignore_term in (False, True):
    with tempfile.TemporaryDirectory(prefix='soak-cleanup-regression-') as directory:
        root = Path(directory)
        # Pass paths as positional parameters; no shell quoting/interpolation of paths.
        harness = '''#!/bin/bash
    set -euo pipefail
    SCRATCH="$1/scratch"; mkdir "$SCRATCH"
    APID=""; TPID=""; HAD_DEFAULTS=1; DOM=test.invalid
    # Verify restoration runs without touching the real defaults tool.
    defaults() { echo "$*" >> "$TEST_DEFAULTS_LOG"; }
    ''' + cleanup + '''
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    set -m
    /usr/bin/time -p /bin/bash -c 'if [ "$2" = 1 ]; then trap "" TERM; fi; echo $$ > "$1"; exec /bin/sleep 60' child "$1/child" "$TEST_IGNORE_TERM" 2>/dev/null &
    TPID=$!
    echo "$TPID" > "$1/group"
    set +m
    for _ in $(seq 1 30); do [ -f "$1/child" ] && break; sleep 0.01; done
    [ -f "$1/child" ]
    kill -TERM "$$"
    '''
        env = dict(os.environ, TEST_DEFAULTS_LOG=str(root / 'defaults-log'), TEST_IGNORE_TERM=str(int(ignore_term)))
        start = time.monotonic()
        try:
            result = subprocess.run(['/bin/bash', '-c', harness, 'regression', directory], env=env, timeout=7)
            elapsed = time.monotonic() - start
            assert result.returncode == 130, result.returncode
            pid = int((root / 'child').read_text())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f'owned child {pid} survived cleanup')
            assert not (root / 'scratch').exists()
            log = (root / 'defaults-log').read_text()
            assert 'delete test.invalid' in log and 'import test.invalid' in log, log
            print(f'PASS early interruption (ignoreTERM={ignore_term}): exit=130 elapsed={elapsed:.2f}s child={pid} gone, defaults restored, scratch removed')
        finally:
            # Keep the regression harness safe even if production cleanup regresses.
            if (root / 'group').exists():
                try:
                    os.killpg(int((root / 'group').read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

# Exercise each production cleanup against a scratch HOME. Prefix lookalikes and
# unrelated domains must survive; each script may remove only its own family.
for script, prefix in [('soak.sh', 'wpq-soak-'), ('verify_app.sh', 'wpq-verify-')]:
    source = (Path(__file__).resolve().parents[2] / 'Scripts' / script).read_text()
    cleanup = source[source.index('cleanup() {'):source.index('\ntrap cleanup EXIT')]
    with tempfile.TemporaryDirectory(prefix='wps-preference-cleanup-') as directory:
        root = Path(directory)
        preferences = root / 'Library/Preferences'
        preferences.mkdir(parents=True)
        domains = ['com.felixfu.MacMonitorPanel.' + prefix + '123',
                   'com.felixfu.MacMonitorPanel.wpu-other-123',
                   'com.felixfu.MacMonitorPanel.' + prefix[:-1],
                   'com.felixfu.MacMonitorPanel']
        for domain in domains:
            plist = preferences / (domain + '.plist')
            plist.write_text('sentinel')
            scratch = root / 'scratch'
            scratch.mkdir()
            harness = '''set -u
DOM="$1"; SCRATCH="$2"; HOME="$3"; APID=""; TPID=""; PID=""; HAD_DEFAULTS=0
BACKUP=""; defaults() { :; }; stop_app() { :; }
''' + cleanup + '\ncleanup\n'
            subprocess.run(['/bin/bash', '-c', harness, 'cleanup', domain, str(scratch), directory], check=True)
            assert plist.exists() == (domain != domains[0]), (script, domain)
        print(f'PASS {script}: own isolated plist removed; unrelated and near-prefix domains preserved')
