#!/usr/bin/env python3
"""Validate resolved Xcode settings before a build; never contacts a live service."""
import base64
import os
import sys
from urllib.parse import urlparse


def validate(settings):
    configuration = settings.get("CONFIGURATION", "")
    production = configuration == "Release"
    expected = "production" if production else "development"
    if configuration not in ("Debug", "Internal", "Release"):
        raise ValueError("CONFIGURATION must be Debug, Internal, or Release")
    if settings.get("PAYBACK_CONVEX_ENV") != expected:
        raise ValueError(f"{configuration} must use PAYBACK_CONVEX_ENV={expected}")
    key = settings.get("PAYBACK_CLERK_PUBLISHABLE_KEY", "")
    prefix = "pk_live_" if production else "pk_test_"
    if not key.startswith(prefix):
        raise ValueError(f"{configuration} requires a {prefix} publishable key in PAYBACK_CLERK_PUBLISHABLE_KEY")
    try:
        payload = key[len(prefix):]
        host = base64.b64decode(payload + "=" * (-len(payload) % 4), validate=True).decode().removesuffix("$")
    except (ValueError, UnicodeDecodeError):
        raise ValueError("PAYBACK_CLERK_PUBLISHABLE_KEY has invalid encoded host") from None
    issuer = settings.get("PAYBACK_CLERK_ISSUER", "")
    parsed = urlparse(issuer)
    if parsed.scheme != "https" or parsed.hostname != host or parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username or parsed.port:
        raise ValueError("PAYBACK_CLERK_ISSUER must be the HTTPS issuer matching the publishable-key host")
    if production and host.endswith(".accounts.dev"):
        raise ValueError("Release cannot use a Clerk development issuer")
    if settings.get("PAYBACK_AUTH_ASSOCIATED_DOMAIN") != f"webcredentials:{host}":
        raise ValueError("PAYBACK_AUTH_ASSOCIATED_DOMAIN must be webcredentials:<Clerk issuer host>")
    if production and settings.get("PAYBACK_AUTH_CONTINUITY_VERIFIED") != "YES":
        raise ValueError("Release blocked: verify existing account-ID continuity, then set PAYBACK_AUTH_CONTINUITY_VERIFIED=YES; see docs/linking/RELEASE_READINESS.md")


if __name__ == "__main__":
    try:
        validate(os.environ)
    except ValueError as error:
        print(f"error: PayBack authentication configuration: {error}", file=sys.stderr)
        sys.exit(1)
