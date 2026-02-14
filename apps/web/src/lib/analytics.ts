import { track } from "@vercel/analytics";

export function trackCtaClick(route: string): void {
  track("testflight_cta_click", { route });
}
