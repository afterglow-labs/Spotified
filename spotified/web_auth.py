"""Single-user server credentials, stored as a salted password hash."""
import base64
import hashlib
import json
from pathlib import Path
import secrets

ITERATIONS = 600_000


def set_credentials(config_dir, username, password):
    if not username or ':' in username or len(username) > 100 or len(password) < 8:
        raise ValueError('Use a username without a colon and a password of at least eight characters.')
    salt = secrets.token_bytes(32)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, ITERATIONS)
    root = Path(config_dir)
    root.mkdir(parents=True, exist_ok=True)
    temporary = root / 'server-auth.tmp'
    with temporary.open('w', encoding='utf-8') as file:
        temporary.chmod(0o600)
        json.dump(dict(username=username, salt=salt.hex(), digest=digest.hex(), iterations=ITERATIONS), file)
    temporary.replace(root / 'server-auth.json')


def verify(credentials, authorization):
    try:
        if not authorization.startswith('Basic '):
            return False
        username, password = base64.b64decode(authorization[6:], validate=True).decode().split(':', 1)
        if len(password) > 1024:
            return False
        digest = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(credentials['salt']), credentials['iterations'])
        return secrets.compare_digest(digest.hex(), credentials['digest']) and secrets.compare_digest(username.encode(), credentials['username'].encode())
    except (ValueError, UnicodeError, KeyError):
        return False
