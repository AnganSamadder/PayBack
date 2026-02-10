import { expect, test } from "@playwright/test";

const routes = ["/", ...Array.from({ length: 31 }, (_, i) => `/v${i + 1}`)];

test("all landing variants render and expose the primary CTA", async ({ page }) => {
  for (const route of routes) {
    await page.goto(route);
    await expect(page.getByRole("button", { name: /try payback on iphone/i }).first()).toBeVisible();
    await expect(page.locator("[data-variant-switcher]")).toBeVisible();
  }
});

test("variant switcher exposes thirty-one buttons", async ({ page }) => {
  await page.goto("/");
  const buttons = page.locator("[data-variant-switcher] a");
  await expect(buttons).toHaveCount(31);
});
