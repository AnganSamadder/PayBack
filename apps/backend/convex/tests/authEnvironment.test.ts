import { describe, expect, it } from "vitest";
import { authConfiguration } from "../authEnvironment";

describe("authentication deployment environment", () => {
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
