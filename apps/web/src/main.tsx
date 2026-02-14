import React from "react";
import ReactDOM from "react-dom/client";
import { RouterProvider } from "@tanstack/react-router";
import { Analytics } from "@vercel/analytics/react";
import { router } from "./router";
import "./styles.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Root element #root not found");
}

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <RouterProvider router={router} />
    <Analytics />
  </React.StrictMode>
);
