import { Outlet } from "@tanstack/react-router";

export function AppShell() {
  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">
        Skip to main content
      </a>
      <main className="route-fade" id="main-content">
        <Outlet />
      </main>
    </div>
  );
}
