#!/usr/bin/env python3
"""Google executable-credential protocol; stdout is consumed by gcloud, not logs."""

import base64
import json
import os
import subprocess
import sys


def main():
    try:
        audience = os.environ["SHOSAI_AMP_OIDC_AUDIENCE"]
        token = subprocess.check_output([
            "amp", "orb", "id-token", "--audience", audience,
            "--subject-scope", "thread", "--ttl-seconds", "600",
        ], text=True, stderr=subprocess.PIPE).strip()
        encoded = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        # This only supplies expiry to the client library. Google verifies the
        # token's signature, issuer, audience and claims before granting access.
        result = {
            "version": 1,
            "success": True,
            "token_type": "urn:ietf:params:oauth:token-type:id_token",
            "id_token": token,
            "expiration_time": int(claims["exp"]),
        }
    except (KeyError, ValueError, IndexError, OSError, subprocess.CalledProcessError):
        print(json.dumps({
            "version": 1, "success": False, "code": "401",
            "message": "Could not obtain the Amp development identity",
        }))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
