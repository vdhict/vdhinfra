"""Test-only RFC 8032 style Ed25519 signer and OpenSSH SK encoding."""
import base64
import hashlib
import struct

Q = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, Q-2, Q) % Q
I = pow(2, (Q-1)//4, Q)


def xrecover(y):
    xx = (y*y-1) * pow(D*y*y+1, Q-2, Q) % Q
    x = pow(xx, (Q+3)//8, Q)
    if (x*x-xx) % Q: x = x*I % Q
    return Q-x if x & 1 else x


B = (xrecover(4*pow(5, Q-2, Q) % Q), 4*pow(5, Q-2, Q) % Q)


def add(p, q):
    x, y = p; u, v = q
    t = D*x*u*y*v
    return ((x*v+u*y)*pow(1+t, Q-2, Q) % Q, (y*v+x*u)*pow(1-t, Q-2, Q) % Q)


def mul(p, n):
    r = (0, 1)
    while n:
        if n & 1: r = add(r, p)
        p = add(p, p); n >>= 1
    return r


def enc(p):
    x, y = p
    return (y | ((x & 1) << 255)).to_bytes(32, 'little')


def h(data): return hashlib.sha512(data).digest()
def integer(data): return int.from_bytes(data, 'little')
def string(data): return struct.pack('>I', len(data)) + data


SEED = bytes(range(32))
HASH = h(SEED)
A = (integer(HASH[:32]) & ((1 << 254)-8)) | (1 << 254)
PUBLIC = enc(mul(B, A))
TYPE = b'sk-ssh-ed25519@openssh.com'
APP = b'ssh:atlas-approval'
PUB = string(TYPE) + string(PUBLIC) + string(APP)
PUBLIC_KEY = TYPE.decode() + ' ' + base64.b64encode(PUB).decode()


def signature(message, flags=5):
    blob = b'SSHSIG' + string(b'atlas-approval') + string(b'') + string(b'sha512') + string(h(message))
    counter = struct.pack('>I', 1)
    signed = hashlib.sha256(APP).digest() + bytes([flags]) + counter + hashlib.sha256(blob).digest()
    r = integer(h(HASH[32:] + signed)) % L
    R = enc(mul(B, r))
    S = (r + integer(h(R + PUBLIC + signed))*A) % L
    sig = string(TYPE) + string(R + S.to_bytes(32, 'little')) + bytes([flags]) + counter
    outer = b'SSHSIG' + struct.pack('>I', 1) + string(PUB) + string(b'atlas-approval') + string(b'') + string(b'sha512') + string(sig)
    return '-----BEGIN SSH SIGNATURE-----\n' + base64.b64encode(outer).decode() + '\n-----END SSH SIGNATURE-----\n'

