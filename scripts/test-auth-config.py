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
    def legacy_settings(self):
        settings = self.settings("Debug")
        settings.update(CONFIGURATION="Release", PAYBACK_CONVEX_ENV="production",
                        PAYBACK_AUTH_PROFILE="legacy-production-tacit-marmot-746")
        return settings

    def test_verified_legacy_production(self):
        settings = self.legacy_settings()
        self.assertEqual(settings["PAYBACK_CLERK_PUBLISHABLE_KEY"],
                         "pk_test_YWNjdXJhdGUtZWFnbGUtODAuY2xlcmsuYWNjb3VudHMuZGV2JA==")
        auth.validate(settings)

    def test_legacy_requires_every_exact_setting(self):
        for key in self.legacy_settings():
            for value in (None, "", "wrong"):
                with self.subTest(key=key, value=value):
                    settings = self.legacy_settings()
                    if value is None:
                        del settings[key]
                    else:
                        settings[key] = value
                    with self.assertRaises(ValueError):
                        auth.validate(settings)

    def test_legacy_rejects_other_provider_and_key_encodings(self):
        other = self.legacy_settings()
        host = "other.clerk.accounts.dev"
        other.update(PAYBACK_CLERK_PUBLISHABLE_KEY="pk_test_" + base64.b64encode((host + "$").encode()).decode(),
                     PAYBACK_CLERK_ISSUER="https://" + host,
                     PAYBACK_AUTH_ASSOCIATED_DOMAIN="webcredentials:" + host)
        with self.assertRaises(ValueError):
            auth.validate(other)
        # The same decoded host with a different prefix or payload is not the verified key.
        key = self.legacy_settings()["PAYBACK_CLERK_PUBLISHABLE_KEY"]
        for alternate in (key.replace("pk_test_", "pk_live_"),
                          "pk_test_" + base64.b64encode(b"accurate-eagle-80.clerk.accounts.dev").decode()):
            settings = self.legacy_settings()
            settings["PAYBACK_CLERK_PUBLISHABLE_KEY"] = alternate
            with self.subTest(key=alternate), self.assertRaises(ValueError):
                auth.validate(settings)

    def test_legacy_rejects_nonexact_issuer_and_verification(self):
        issuer = self.legacy_settings()["PAYBACK_CLERK_ISSUER"]
        for value in (issuer + "/", issuer + ":443", issuer + "/path", issuer + "?query",
                      issuer + "#fragment", issuer.replace("https://", "https://user@"),
                      issuer.replace("https://", "http://")):
            settings = self.legacy_settings()
            settings["PAYBACK_CLERK_ISSUER"] = value
            with self.subTest(issuer=value), self.assertRaises(ValueError):
                auth.validate(settings)
        settings = self.legacy_settings()
        settings["PAYBACK_AUTH_CONTINUITY_VERIFIED"] = "yes"
        with self.assertRaises(ValueError):
            auth.validate(settings)

    def test_profile_cannot_be_used_for_debug_internal_or_modern_provider(self):
        for configuration in ("Debug", "Internal", "Release"):
            settings = self.settings(configuration)
            settings["PAYBACK_AUTH_PROFILE"] = "legacy-production-tacit-marmot-746"
            with self.subTest(configuration=configuration), self.assertRaises(ValueError):
                auth.validate(settings)

    def test_unknown_profiles_fail_closed(self):
        for profile in ("legacy-production", "modern-production", " ", " legacy-production-tacit-marmot-746"):
            for configuration in ("Debug", "Internal", "Release"):
                settings = self.settings(configuration)
                settings["PAYBACK_AUTH_PROFILE"] = profile
                with self.subTest(profile=profile, configuration=configuration), self.assertRaisesRegex(ValueError, "profile"):
                    auth.validate(settings)

    def test_empty_profile_retains_modern_production_guards(self):
        for profile in (None, ""):
            modern = self.settings("Release")
            legacy = self.legacy_settings()
            for settings in (modern, legacy):
                settings.pop("PAYBACK_AUTH_PROFILE", None)
                if profile is not None:
                    settings["PAYBACK_AUTH_PROFILE"] = profile
            auth.validate(modern)
            with self.assertRaises(ValueError):
                auth.validate(legacy)
            # A pk_live key alone must not permit a development issuer.
            legacy["PAYBACK_CLERK_PUBLISHABLE_KEY"] = legacy["PAYBACK_CLERK_PUBLISHABLE_KEY"].replace("pk_test_", "pk_live_")
            with self.assertRaisesRegex(ValueError, "development issuer"):
                auth.validate(legacy)

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
        self.assertEqual(release["PAYBACK_AUTH_PROFILE"], "$(PAYBACK_PRODUCTION_AUTH_PROFILE)")
        self.assertEqual(release["PAYBACK_AUTH_CONTINUITY_VERIFIED"], "$(PAYBACK_PRODUCTION_AUTH_CONTINUITY_VERIFIED)")
        for supplied in (self.settings("Release"), self.legacy_settings()):
            resolved = {key: supplied.get(key, "") if str(value).startswith("$(PAYBACK_PRODUCTION_") else value for key, value in release.items()}
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
