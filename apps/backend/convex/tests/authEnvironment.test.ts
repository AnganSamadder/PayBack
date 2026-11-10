import { describe, expect, it } from "vitest";
import { authConfiguration } from "../authEnvironment";

const legacyProduction = {
  PAYBACK_AUTH_PROFILE: "legacy-production-tacit-marmot-746",
  PAYBACK_AUTH_ENV: "production",
  CONVEX_CLOUD_URL: "https://tacit-marmot-746.convex.cloud",
  CLERK_JWT_ISSUER_DOMAIN: "https://accurate-eagle-80.clerk.accounts.dev",
  PAYBACK_AUTH_CONTINUITY_VERIFIED: "YES"
};

describe("authentication deployment environment", () => {
  it("preserves only the explicitly verified existing production provider", () => {
    expect(authConfiguration(legacyProduction)).toEqual({
      providers: [
        { domain: "https://accurate-eagle-80.clerk.accounts.dev", applicationID: "convex" }
      ]
    });
  });

  it.each<[string, string | undefined]>([
    ["PAYBACK_AUTH_ENV", undefined],
    ["PAYBACK_AUTH_ENV", "development"],
    ["PAYBACK_AUTH_ENV", "Production"],
    ["CONVEX_CLOUD_URL", undefined],
    ["CONVEX_CLOUD_URL", "https://flippant-bobcat-304.convex.cloud"],
    ["CONVEX_CLOUD_URL", "https://other-production.convex.cloud"],
    ["CONVEX_CLOUD_URL", "https://tacit-marmot-746.convex.cloud/"],
    ["CLERK_JWT_ISSUER_DOMAIN", undefined],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://other.clerk.accounts.dev"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://clerk.example.test"],
    ["CLERK_JWT_ISSUER_DOMAIN", "http://accurate-eagle-80.clerk.accounts.dev"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://accurate-eagle-80.clerk.accounts.dev/"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://user@accurate-eagle-80.clerk.accounts.dev"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://accurate-eagle-80.clerk.accounts.dev:443"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://accurate-eagle-80.clerk.accounts.dev/path"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://accurate-eagle-80.clerk.accounts.dev?query"],
    ["CLERK_JWT_ISSUER_DOMAIN", "https://accurate-eagle-80.clerk.accounts.dev#fragment"],
    ["PAYBACK_AUTH_CONTINUITY_VERIFIED", undefined],
    ["PAYBACK_AUTH_CONTINUITY_VERIFIED", ""],
    ["PAYBACK_AUTH_CONTINUITY_VERIFIED", "yes"]
  ])("rejects legacy production when %s is %s", (key, value) => {
    expect(() => authConfiguration({ ...legacyProduction, [key]: value })).toThrow();
  });

  it.each(["legacy-production", "modern-production", " legacy-production-tacit-marmot-746", " "])(
    "fails closed on unknown profile %s even with otherwise valid modern or development settings",
    (profile) => {
      for (const environment of [
        legacyProduction,
        {
          PAYBACK_AUTH_ENV: "production",
          CLERK_JWT_ISSUER_DOMAIN: "https://clerk.example.test",
          PAYBACK_AUTH_CONTINUITY_VERIFIED: "YES"
        },
        { CONVEX_CLOUD_URL: "https://flippant-bobcat-304.convex.cloud" }
      ]) {
        expect(() => authConfiguration({ ...environment, PAYBACK_AUTH_PROFILE: profile })).toThrow(
          /profile/
        );
      }
    }
  );

  it.each([undefined, ""])("keeps modern production strict when profile is %s", (profile) => {
    const environment = { ...legacyProduction, PAYBACK_AUTH_PROFILE: profile };
    expect(() => authConfiguration(environment)).toThrow(/production Clerk/);
    expect(
      authConfiguration({ ...environment, CLERK_JWT_ISSUER_DOMAIN: "https://clerk.example.test" })
        .providers
    ).toEqual([{ domain: "https://clerk.example.test", applicationID: "convex" }]);
  });

  it("retains the known development issuer for the existing development deployment", () => {
    expect(
      authConfiguration({ CONVEX_CLOUD_URL: "https://flippant-bobcat-304.convex.cloud" })
        .providers[0].domain
    ).toBe("https://accurate-eagle-80.clerk.accounts.dev");
  });
  it("requires explicit production issuer and verified account continuity", () => {
    const environment = {
      PAYBACK_AUTH_ENV: "production",
      CLERK_JWT_ISSUER_DOMAIN: "https://clerk.example.test",
      PAYBACK_AUTH_CONTINUITY_VERIFIED: "YES"
    };
    expect(authConfiguration(environment).providers[0].domain).toBe("https://clerk.example.test");
    expect(() =>
      authConfiguration({ ...environment, PAYBACK_AUTH_CONTINUITY_VERIFIED: undefined })
    ).toThrow(/continuity/);
    expect(() =>
      authConfiguration({
        ...environment,
        CLERK_JWT_ISSUER_DOMAIN: "https://accurate-eagle-80.clerk.accounts.dev"
      })
    ).toThrow(/production Clerk/);
  });
  it("rejects production issuer on the development deployment", () => {
    expect(() =>
      authConfiguration({
        PAYBACK_AUTH_ENV: "development",
        CLERK_JWT_ISSUER_DOMAIN: "https://clerk.example.test"
      })
    ).toThrow(/do not match/);
    expect(() =>
      authConfiguration({
        PAYBACK_AUTH_ENV: "production",
        CLERK_JWT_ISSUER_DOMAIN: "https://clerk.example.test",
        CONVEX_CLOUD_URL: "https://flippant-bobcat-304.convex.cloud"
      })
    ).toThrow(/do not match/);
  });
  it("fails closed on unknown deployments and development/production mismatch", () => {
    expect(() => authConfiguration({})).toThrow(/Configure/);
    expect(() =>
      authConfiguration({
        CONVEX_CLOUD_URL: "https://tacit-marmot-746.convex.cloud",
        PAYBACK_AUTH_ENV: "development"
      })
    ).toThrow(/different Convex/);
  });
});
