import { useQuery } from "@tanstack/react-query";
import { api, qs } from "./api";
import type {
  AlertStatus,
  ChannelTarget,
  AuditEvent,
  ConsoleAuditEvent,
  FleetInstallation,
  Installation,
  InstallationStatus,
  IntegrationSwitch,
  Me,
  Operator,
  Purchase,
  BankSettings,
  TopUp,
  TopUpDetail,
  Wallet,
  WalletEntry,
} from "./types";

// Query keys are arrays rooted at the API area, so an action can refresh a
// whole area ("wallet") or one shop's slice of it.

export const keys = {
  me: ["me"],
  installations: ["installations"],
  installation: (id: string) => ["installations", id],
  status: (id: string) => ["installations", id, "status"],
  installationAudit: (id: string) => ["installations", id, "audit"],
  wallets: ["wallet", "wallets"],
  entries: (id: string, account: string) => ["wallet", "entries", id, account],
  topUps: (filter: Record<string, string>) => ["wallet", "topups", filter],
  topUp: (id: string) => ["wallet", "topup", id],
  bankAccounts: ["wallet", "bank-accounts"],
  purchases: (filter: Record<string, string>) => ["vouchers", "purchases", filter],
  operators: ["operators"],
  audit: (filter: Record<string, string>) => ["audit", filter],
  integrations: ["integrations"],
  alerts: ["alerts"],
  fleet: ["fleet"],
};

export function useMe() {
  return useQuery({
    queryKey: keys.me,
    queryFn: async () => {
      try {
        return await api.get<Me>("/auth/me");
      } catch {
        return null;
      }
    },
    staleTime: 60_000,
    refetchOnWindowFocus: true,
  });
}

export function useInstallations() {
  return useQuery({
    queryKey: keys.installations,
    queryFn: () => api.get<{ installations: Installation[] }>("/v1/installations" + qs({ limit: 1000 })).then((r) => r.installations ?? []),
    staleTime: 30_000,
  });
}

export function useInstallation(id: string) {
  return useQuery({
    queryKey: keys.installation(id),
    queryFn: () => api.get<Installation>(`/v1/installations/${encodeURIComponent(id)}`),
  });
}

export function useInstallationStatus(id: string) {
  return useQuery({
    queryKey: keys.status(id),
    queryFn: () => api.get<InstallationStatus>(`/v1/installations/${encodeURIComponent(id)}/status`),
    refetchInterval: 30_000,
  });
}

export function useInstallationAudit(id: string) {
  return useQuery({
    queryKey: keys.installationAudit(id),
    queryFn: () =>
      api.get<{ events: AuditEvent[] }>(`/v1/installations/${encodeURIComponent(id)}/audit-events` + qs({ limit: 50 })).then((r) => r.events ?? []),
  });
}

export function useWallets() {
  return useQuery({
    queryKey: keys.wallets,
    // The listing is per account (it defaults to the main wallet).
    queryFn: async () => {
      const lists = await Promise.all(
        ["main", "sms", "vouchers"].map((account) =>
          api.get<{ wallets: Wallet[] }>("/v1/wallet/admin/wallets" + qs({ account, limit: 500 })).then((r) =>
            (r.wallets ?? []).map((w) => ({ ...w, account: w.account || account })),
          ),
        ),
      );
      return { wallets: lists.flat() };
    },
    staleTime: 20_000,
  });
}

export function useEntries(installationId: string, account = "") {
  return useQuery({
    queryKey: keys.entries(installationId, account),
    queryFn: () =>
      api
        .get<{ entries: WalletEntry[] }>("/v1/wallet/admin/entries" + qs({ installation_id: installationId, account, limit: 200 }))
        .then((r) => r.entries ?? []),
  });
}

export function useTopUps(filter: Record<string, string>) {
  return useQuery({
    queryKey: keys.topUps(filter),
    queryFn: () => api.get<{ topups: TopUp[] }>("/v1/wallet/admin/topups" + qs({ ...filter, limit: 200 })).then((r) => r.topups ?? []),
    refetchInterval: 30_000,
  });
}

export function useTopUp(id: string) {
  return useQuery({
    queryKey: keys.topUp(id),
    queryFn: () => api.get<TopUpDetail>(`/v1/wallet/admin/topups/${encodeURIComponent(id)}`),
    // A transfer someone else is reviewing changes under you.
    refetchInterval: 20_000,
  });
}

export function useBankAccounts() {
  return useQuery({
    queryKey: keys.bankAccounts,
    queryFn: () => api.get<BankSettings>("/v1/wallet/admin/bank-accounts"),
  });
}

export function usePurchases(filter: Record<string, string>) {
  return useQuery({
    queryKey: keys.purchases(filter),
    queryFn: () =>
      api.get<{ purchases: Purchase[] }>("/v1/vouchers/admin/purchases" + qs({ ...filter, limit: 200 })).then((r) => r.purchases ?? []),
    refetchInterval: 30_000,
    retry: false,
  });
}

export function useOperators() {
  return useQuery({
    queryKey: keys.operators,
    queryFn: () => api.get<{ operators: Operator[] }>("/operators").then((r) => r.operators ?? []),
  });
}

export function useConsoleAudit(filter: Record<string, string>) {
  return useQuery({
    queryKey: keys.audit(filter),
    queryFn: () => api.get<{ events: ConsoleAuditEvent[] }>("/audit" + qs({ ...filter, limit: 200 })).then((r) => r.events ?? []),
  });
}

export function useIntegrations() {
  return useQuery({
    queryKey: keys.integrations,
    queryFn: () => api.get<{ integrations: IntegrationSwitch[] }>("/v1/fleet/integrations").then((r) => r.integrations ?? []),
    retry: false,
  });
}

export function useAlerts() {
  return useQuery({
    queryKey: keys.alerts,
    queryFn: () => api.get<AlertStatus>("/v1/alerts"),
    retry: false,
  });
}

export function useFleet() {
  return useQuery({
    queryKey: keys.fleet,
    queryFn: () =>
      api
        .get<{ installations: FleetInstallation[]; channels: ChannelTarget[]; minimum_version?: string; unknown_version_count?: number }>("/v1/fleet")
        .then((r) => ({ ...r, installations: r.installations ?? [], channels: r.channels ?? [] })),
    staleTime: 60_000,
    retry: false,
  });
}
