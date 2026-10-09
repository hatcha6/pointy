import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import "@fontsource/ibm-plex-sans-arabic/arabic-400.css";
import "@fontsource/ibm-plex-sans-arabic/arabic-500.css";
import "@fontsource/ibm-plex-sans-arabic/arabic-600.css";
import "@fontsource/ibm-plex-sans-arabic/arabic-700.css";
import "@fontsource/ibm-plex-sans-arabic/latin-400.css";
import "@fontsource/ibm-plex-sans-arabic/latin-600.css";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/ui.css";
import "./styles/responsive.css";
import { App } from "./App";
import { RouterProvider } from "./lib/router";
import { ToastProvider } from "./components/toast";
import { ApiError } from "./lib/api";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      refetchOnWindowFocus: true,
      retry: (failures, error) => !(error instanceof ApiError && error.status > 0 && error.status < 500) && failures < 2,
    },
  },
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider>
        <ToastProvider>
          <App />
        </ToastProvider>
      </RouterProvider>
    </QueryClientProvider>
  </StrictMode>,
);
