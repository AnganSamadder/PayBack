const rawTestflightUrl = import.meta.env.VITE_TESTFLIGHT_URL?.trim();
let warned = false;

export const testflightUrl = rawTestflightUrl || "#";
export const hasTestflightUrl = Boolean(rawTestflightUrl);

export function warnMissingTestflightUrl(): void {
  if (!hasTestflightUrl && !warned) {
    warned = true;
    console.warn("VITE_TESTFLIGHT_URL is missing. CTA buttons are disabled.");
  }
}
