export type Installation = {
  id: string;
  business_id: string;
  shop_name: string;
  relay_enabled: boolean;
  subscription_active: boolean;
  subscription_ends_at: string | null;
  ai_enabled: boolean;
  fx_enabled: boolean;
  remote_access_paid_until: string | null;
  ai_paid_until: string | null;
  relay_active: boolean;
  ai_active: boolean;
  created_at: string;
  updated_at: string;
  last_connector_connected_at: string | null;
  connector_certificate_expires_at: string | null;
};

export type InstallationStatus = {
  installation_id: string;
  connector_online_local: boolean;
  connector_presence: { online: boolean; connected_at?: string; refreshed_at?: string; node_id?: string };
  last_connector_connected_at: string | null;
  connector_certificate_expires_at: string | null;
  connector_certificate_expires_in_seconds?: number;
};

export type Wallet = { installation_id: string; account: string; shop_name?: string; balance: string; updated_at?: string };

export type WalletEntry = {
  id: string;
  installation_id: string;
  shop_name?: string;
  account: string;
  kind: string;
  service?: string;
  amount: string;
  balance_after: string;
  reference?: string;
  description?: string;
  actor?: string;
  test_mode?: boolean;
  created_at: string;
};

export type TopUp = {
  id: string;
  installation_id: string;
  shop_name?: string;
  method: string;
  amount: string;
  status: string;
  invoice_no?: string;
  provider_transaction_id?: string;
  requested_by?: string;
  payer_hint?: string;
  test_mode?: boolean;
  error_code?: string;
  error_detail?: string;
  confirmed_by?: string;
  created_at: string;
  updated_at: string;
  paid_at?: string | null;
  transfer?: BankTransfer | null;
};

/** What a shop told us about a bank transfer to our account. */
export type BankTransfer = {
  channel: string;
  payer_bank: string;
  payer_account: string;
  payer_iban: string;
  to_account?: string;
  receipt: { sha256: string; content_type: string; name?: string; size: number };
  declared_amount?: string;
  rejected_by?: string;
  rejected_at?: string;
};

/** One of our accounts a shop may transfer to. */
export type BankAccount = {
  id: string;
  bank: string;
  bank_name: string;
  holder: string;
  account_number: string;
  iban: string;
  enabled: boolean;
};

export type BankSettings = { accounts: BankAccount[]; updated_at?: string; updated_by?: string };

export type TopUpDetail = { top_up: TopUp; account?: BankAccount; duplicates: TopUp[] };

export type Purchase = {
  id: string;
  installation_id: string;
  shop_name?: string;
  kind: string;
  item: string;
  brand: string;
  name: string;
  quantity: number;
  target?: string;
  unit_price: string;
  amount: string;
  supplier: string;
  supplier_order_id?: string;
  supplier_cost?: string;
  supplier_currency?: string;
  status: string;
  error_code?: string;
  error_detail?: string;
  test_mode?: boolean;
  requested_by?: string;
  held_since?: string | null;
  created_at: string;
  completed_at?: string | null;
};

export type AuditEvent = {
  id: string;
  installation_id?: string;
  action: string;
  actor: string;
  reason: string;
  created_at: string;
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
};

export type ConsoleAuditEvent = {
  id: string;
  at: string;
  operator_id: string;
  operator_name: string;
  action: string;
  method: string;
  path: string;
  status: number;
  body?: string;
  ip: string;
  stepped_up: boolean;
};

export type Operator = {
  id: string;
  name: string;
  created_at: string;
  created_by: string;
  disabled_at?: string | null;
  passkeys: { id: string; label: string; created_at: string; last_used_at: string | null }[];
  sessions: { id: string; created_at: string; last_seen_at: string; ip: string; user_agent: string; current: boolean }[];
};

export type Me = {
  operator: { id: string; name: string };
  session: { id: string; created_at: string; expires_at: string; max_age_at: string };
  idle_timeout_seconds: number;
};

export type IntegrationSwitch = {
  provider: string;
  disabled: boolean;
  reason?: string;
  actor?: string;
  updated_at?: string;
};

export type AlertStatus = {
  configured: boolean;
  server: string;
  topic?: string;
  subscribe_url?: string;
  updated_at?: string;
  actor?: string;
};

export type ChannelTarget = {
  channel: string;
  target_version: string;
  rollout_phase: string;
  rollout_percent?: number;
  canary_ids?: string[];
  updated_at?: string;
};

export type ArtifactMeta = { version: string; sha256: string; size: number; created_at: string };

export type ArtifactFetch = {
  version: string;
  url: string;
  state: string;
  bytes_received: number;
  bytes_total: number;
  retries?: number;
  retry_reason?: string;
  error?: string;
  started_at: string;
  finished_at?: string;
  artifact?: ArtifactMeta;
};

export type FleetInstallation = {
  id: string;
  shop_name: string;
  channel: string;
  current_version: string;
  assigned_version: string;
  directive: string;
  pinned_version: string;
  update_status: string;
  update_error: string;
  agent_version: string;
  agent_last_seen_at: string | null;
  last_update_at: string | null;
};
