"""chg-2026-10-15-001 C5/C6 probe, run INSIDE a pod that carries the huiswerk-refresh labels, image, passwd and
export-key mounts (no PVC, no fill). Prints exit codes, byte counts and sha256 prefixes only; the export tar is
hashed in memory and discarded."""
import hashlib, socket, subprocess, time

BASE = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'UserKnownHostsFile=/run/ssh/known_hosts', '-i', '/run/ssh/key']
HOST = 'sheijden@172.16.2.201'


def run(label, extra, cmd):
    r = subprocess.run(BASE + extra + [HOST] + cmd, capture_output=True, timeout=60)
    sha = hashlib.sha256(r.stdout).hexdigest()[:12] if r.stdout else '-'
    print(f'{label}: rc={r.returncode} bytes={len(r.stdout)} sha256={sha} stderr_lines={len(r.stderr.splitlines())}')
    return r


plain = run('plain', [], ['huiswerk-export'])
run('cmd cat /etc/passwd', [], ['cat', '/etc/passwd'])
run('subsystem sftp', ['-s'], ['sftp'])
r = run('remote forward -R', ['-N', '-o', 'ExitOnForwardFailure=yes', '-R', '0:127.0.0.1:22'], [])
print('  -R refused:', b'forwarding failed' in r.stderr or b'refused' in r.stderr.lower())
p = subprocess.Popen(BASE + ['-N', '-L', '127.0.0.1:2222:127.0.0.1:22', HOST], stdout=subprocess.DEVNULL,
                     stderr=subprocess.PIPE)
time.sleep(4)
got = b''
try:
    s = socket.create_connection(('127.0.0.1', 2222), timeout=5)
    s.settimeout(5)
    try:
        got = s.recv(64)
    except OSError:
        pass
    s.close()
except OSError as e:
    print('  -L local connect:', type(e).__name__)
time.sleep(1)
p.terminate()
err = p.communicate(timeout=10)[1]
print(f'local forward -L: banner_bytes_through={len(got)} prohibited={b"prohibited" in err or b"open failed" in err}')
r = run('pty request -t', ['-tt'], [])
import os
for label, host, port in (('dns kennisdienst name', 'kennisdienst.family-ai.svc.cluster.local', 8088),
                          ('kennisdienst svc IP:8088', os.environ['KD_SVC'], 8088),
                          ('kennisdienst pod IP:8088', os.environ['KD_POD'], 8088),
                          ('1.1.1.1:443', '1.1.1.1', 443),
                          ('Mini:22 control', '172.16.2.201', 22)):
    try:
        s = socket.create_connection((host, port), timeout=5)
        s.close()
        print(f'egress {label}: CONNECTED')
    except OSError as e:
        print(f'egress {label}: {type(e).__name__}')
