import { test, expect } from "@playwright/test";

test("landing page has title", async ({ page }) => {
  await page.goto("/");

  await expect(page).toHaveTitle(/PayBack/);
});
