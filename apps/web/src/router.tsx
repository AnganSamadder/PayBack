import {
  createRootRoute,
  createRoute,
  createRouter,
  lazyRouteComponent
} from "@tanstack/react-router";
import { AppShell } from "./app/AppShell";

const rootRoute = createRootRoute({
  component: AppShell
});

const homeRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: lazyRouteComponent(() => import("./Home"))
});

const routeTree = rootRoute.addChildren([homeRoute]);

export const router = createRouter({
  routeTree,
  defaultPreload: "intent",
  defaultPreloadStaleTime: 0
});

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
