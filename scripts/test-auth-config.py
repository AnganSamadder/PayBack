#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True
import base64
import importlib.util
import pathlib
import json
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("auth", pathlib.Path(__file__).with_name("validate-auth-config.py"))
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


class AuthConfigurationTests(unittest.TestCase):
    def settings(self, configuration):
        production = configuration == "Release"
        host = "clerk.example.test" if production else "accurate-eagle-80.clerk.accounts.dev"
        return dict(CONFIGURATION=configuration, PAYBACK_CONVEX_ENV="production" if production else "development",
                    PAYBACK_CLERK_PUBLISHABLE_KEY=("pk_live_" if production else "pk_test_") + base64.b64encode((host + "$" ).encode()).decode(),
                    PAYBACK_CLERK_ISSUER="https://" + host, PAYBACK_AUTH_ASSOCIATED_DOMAIN="webcredentials:" + host,
                    PAYBACK_AUTH_CONTINUITY_VERIFIED="YES")

    def test_matrix(self):
        for configuration in ("Debug", "Internal", "Release"):
            auth.validate(self.settings(configuration))

    def test_project_build_settings_and_entitlements(self):
        root = pathlib.Path(__file__).resolve().parent.parent
        project = json.loads(subprocess.check_output([
            "ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(root / "project.yml")
        ]))
        target = project["targets"]["PayBack"]
        configurations = target["settings"]["configs"]
        for configuration in ("Debug", "Internal"):
            auth.validate(dict(configurations[configuration], CONFIGURATION=configuration))
        release = configurations["Release"]
        with self.assertRaises(ValueError):
            auth.validate(dict(release, CONFIGURATION="Release"))
        supplied = self.settings("Release")
        resolved = {key: supplied[key] if str(value).startswith("$(PAYBACK_PRODUCTION_") else value for key, value in release.items()}
        auth.validate(dict(resolved, CONFIGURATION="Release"))
        self.assertEqual(target["entitlements"]["properties"]["com.apple.developer.associated-domains"], ["$(PAYBACK_AUTH_ASSOCIATED_DOMAIN)"])
        self.assertTrue(any("validate-auth-config.py" in item["script"] for item in target["preBuildScripts"]))

    def test_every_required_value_rejects_missing_and_mismatch(self):
        for key in self.settings("Release"):
            for value in ("", "wrong"):
                with self.subTest(key=key, value=value):
                    settings = self.settings("Release")
                    settings[key] = value
                    with self.assertRaises(ValueError):
                        auth.validate(settings)

    def test_release_rejects_development_key(self):
        settings = self.settings("Debug")
        settings.update(CONFIGURATION="Release", PAYBACK_CONVEX_ENV="production")
        with self.assertRaises(ValueError):
            auth.validate(settings)


unittest.main()
