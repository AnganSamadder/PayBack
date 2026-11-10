/** Pure deployment validation. Changing issuers requires an account-continuity rollout. */
export function authConfiguration(environment: Record<string, string | undefined>) {
  const profile = environment.PAYBACK_AUTH_PROFILE;
  if (profile && profile !== "legacy-production-tacit-marmot-746") {
    throw new Error(
      "Unknown authentication profile in PAYBACK_AUTH_PROFILE; leave unset for modern production"
    );
  }
  if (profile === "legacy-production-tacit-marmot-746") {
    // Preserve the verified existing provider only; never infer this profile from the URL.
    if (
      environment.PAYBACK_AUTH_ENV !== "production" ||
      environment.CONVEX_CLOUD_URL !== "https://tacit-marmot-746.convex.cloud" ||
      environment.CLERK_JWT_ISSUER_DOMAIN !== "https://accurate-eagle-80.clerk.accounts.dev"
    ) {
      throw new Error(
        "Legacy production profile requires the exact verified deployment and issuer"
      );
    }
    if (environment.PAYBACK_AUTH_CONTINUITY_VERIFIED !== "YES") {
      throw new Error(
        "Legacy production profile requires explicit account continuity verification"
      );
    }
    return {
      providers: [
        { domain: "https://accurate-eagle-80.clerk.accounts.dev", applicationID: "convex" }
      ]
    };
  }
  const developmentIssuer = "https://accurate-eagle-80.clerk.accounts.dev";
  const developmentURL = "https://flippant-bobcat-304.convex.cloud";
  const mode = environment.PAYBACK_AUTH_ENV;
  const cloudURL = environment.CONVEX_CLOUD_URL;
  const isDevelopment = mode === "development" || (!mode && cloudURL === developmentURL);
  const issuer =
    environment.CLERK_JWT_ISSUER_DOMAIN ?? (isDevelopment ? developmentIssuer : undefined);
  if (!issuer) {
    throw new Error(
      "Configure PAYBACK_AUTH_ENV and CLERK_JWT_ISSUER_DOMAIN before deployment; see docs/linking/RELEASE_READINESS.md"
    );
  }
  const url = new URL(issuer);
  if (
    url.protocol !== "https:" ||
    url.pathname !== "/" ||
    url.search ||
    url.hash ||
    url.username ||
    url.port
  ) {
    throw new Error("CLERK_JWT_ISSUER_DOMAIN must be an HTTPS issuer origin");
  }
  if (!isDevelopment && (mode !== "production" || url.hostname.endsWith(".accounts.dev"))) {
    throw new Error(
      "Production requires PAYBACK_AUTH_ENV=production and a production Clerk issuer"
    );
  }
  if (
    (isDevelopment && url.origin !== developmentIssuer) ||
    (!isDevelopment && cloudURL === developmentURL)
  ) {
    throw new Error("Clerk issuer and Convex deployment environments do not match");
  }
  if (isDevelopment && cloudURL && cloudURL !== developmentURL) {
    throw new Error(
      "Development Clerk configuration cannot be deployed to a different Convex environment"
    );
  }
  if (!isDevelopment && environment.PAYBACK_AUTH_CONTINUITY_VERIFIED !== "YES") {
    throw new Error(
      "Verify existing account-ID continuity before changing the production issuer; set PAYBACK_AUTH_CONTINUITY_VERIFIED=YES only after verification"
    );
  }
  return { providers: [{ domain: url.origin, applicationID: "convex" }] };
}
