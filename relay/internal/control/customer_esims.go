package control

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The eSIMs of «دفتر كروت» customers, and the eSIM shelf's catalog.
//
// An eSIM is bought by a customer order like any card (customer_orders.go); this
// row is what remains afterwards: whose it is, which plan, and what was last
// read about its usage. What installs it (the activation code, the share link)
// is deliberately NOT here: like a card's code it stays with the supplier and
// is read back on demand, so a copy of the relay's database installs nothing.

// ErrCustomerESIMNotFound is an ICCID this relay did not sell.
var ErrCustomerESIMNotFound = errors.New("customer esim not found")

const maxCustomerESIMLabel = 60

// CustomerESIM is one eSIM a customer bought.
type CustomerESIM struct {
	ICCID      string `json:"iccid"`
	CustomerID string `json:"customer_id"`
	OrderID    string `json:"order_id"`
	PackageID  string `json:"package_id"`
	// Title and Data are the plan as sold ("1 GB - 7 days", "1 GB").
	Title    string `json:"title"`
	Data     string `json:"data"`
	Days     int    `json:"days"`
	Operator string `json:"operator"`
	// Destination is the shelf's key for where it works; DestinationName and
	// Image are as they read at purchase.
	Destination     string `json:"destination"`
	DestinationName string `json:"destination_name"`
	// Country is the destination's ISO code; empty for a region or the world.
	Country      string `json:"country,omitempty"`
	Image        string `json:"image"`
	Unlimited    bool   `json:"unlimited"`
	Rechargeable bool   `json:"rechargeable"`
	// Label names who it is for, in the buyer's words: empty is their own.
	Label string `json:"label,omitempty"`
	// Gift says it was bought for someone else's phone.
	Gift bool `json:"gift,omitempty"`
	// Simulated: bought in test mode or by the stores' review account. No
	// supplier knows it.
	Simulated bool `json:"simulated,omitempty"`
	TestMode  bool `json:"test_mode"`
	// Usage as last read: status (NOT_ACTIVE, ACTIVE, FINISHED, EXPIRED,
	// UNKNOWN), megabytes, when it ends, and when this was read.
	UsageStatus string     `json:"usage_status,omitempty"`
	RemainingMB int        `json:"remaining_mb"`
	TotalMB     int        `json:"total_mb"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
	UsageAt     *time.Time `json:"usage_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

// CustomerESIMUsage is one reading of an eSIM's usage.
type CustomerESIMUsage struct {
	Status      string
	RemainingMB int
	TotalMB     int
	ExpiresAt   *time.Time
}

// ESIMCatalogDocument is the shelf's catalog as last synced: one JSON document,
// shared by every relay node. Version changes when its content does.
type ESIMCatalogDocument struct {
	Version  string    `json:"version"`
	Document string    `json:"document"`
	SyncedAt time.Time `json:"synced_at"`
}

// CustomerESIMStore is an optional store capability (type-asserted).
type CustomerESIMStore interface {
	// SaveCustomerESIM records an eSIM once: saved again it keeps the first
	// row, so a repeated delivery changes nothing.
	SaveCustomerESIM(ctx context.Context, esim CustomerESIM) (CustomerESIM, error)
	GetCustomerESIM(ctx context.Context, iccid string) (CustomerESIM, error)
	// CustomerESIMByOrder is the eSIM an order issued.
	CustomerESIMByOrder(ctx context.Context, customerID, orderID string) (CustomerESIM, error)
	// ListCustomerESIMs is the customer's eSIMs, newest first.
	ListCustomerESIMs(ctx context.Context, customerID string) ([]CustomerESIM, error)
	UpdateCustomerESIMUsage(ctx context.Context, iccid string, usage CustomerESIMUsage) error
	// RenameCustomerESIM sets who an eSIM of this customer is for.
	RenameCustomerESIM(ctx context.Context, customerID, iccid, label string) (CustomerESIM, error)
	// ClaimCustomerESIMNotice reports whether this alert (a level on a package)
	// is new for the eSIM: Airalo may deliver one up to 20 times, the customer
	// hears it once.
	ClaimCustomerESIMNotice(ctx context.Context, iccid, level, packageName string) (bool, error)
	// ClearCustomerESIMNotices starts the alerts over: a top-up gave the eSIM
	// a new package that will cross the same levels.
	ClearCustomerESIMNotices(ctx context.Context, iccid string) error
	// ForgetCustomerESIMs removes a customer's eSIMs when they delete their account.
	ForgetCustomerESIMs(ctx context.Context, customerID string) error

	// ESIMCatalogVersion is the stored catalog's version and sync time, without
	// the document; both zero when none was ever synced.
	ESIMCatalogVersion(ctx context.Context) (string, time.Time, error)
	ReadESIMCatalog(ctx context.Context) (ESIMCatalogDocument, error)
	SaveESIMCatalog(ctx context.Context, catalog ESIMCatalogDocument) error
}

var (
	_ CustomerESIMStore = (*FileStore)(nil)
	_ CustomerESIMStore = (*PostgresStore)(nil)
	_ CustomerESIMStore = (*CachedInstallationStore)(nil)
)

func normalizeCustomerESIMLabel(label string) string {
	return truncateRunes(strings.TrimSpace(label), maxCustomerESIMLabel)
}

func customerESIMNoticeKey(iccid, level, packageName string) string {
	return iccid + "\x00" + level + "\x00" + packageName
}

// --- file store ------------------------------------------------------------

func (s *FileStore) SaveCustomerESIM(_ context.Context, esim CustomerESIM) (CustomerESIM, error) {
	esim.ICCID = strings.TrimSpace(esim.ICCID)
	if esim.ICCID == "" || esim.CustomerID == "" {
		return CustomerESIM{}, errors.New("a customer esim needs an iccid and a customer")
	}
	esim.Label = normalizeCustomerESIMLabel(esim.Label)
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing, ok := s.data.CustomerESIMs[esim.ICCID]; ok {
		return existing, nil
	}
	now := s.clock.Now()
	esim.CreatedAt, esim.UpdatedAt = now, now
	if s.data.CustomerESIMs == nil {
		s.data.CustomerESIMs = map[string]CustomerESIM{}
	}
	s.data.CustomerESIMs[esim.ICCID] = esim
	if err := s.saveLocked(); err != nil {
		delete(s.data.CustomerESIMs, esim.ICCID)
		return CustomerESIM{}, err
	}
	return esim, nil
}

func (s *FileStore) GetCustomerESIM(_ context.Context, iccid string) (CustomerESIM, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	esim, ok := s.data.CustomerESIMs[strings.TrimSpace(iccid)]
	if !ok {
		return CustomerESIM{}, ErrCustomerESIMNotFound
	}
	return esim, nil
}

func (s *FileStore) CustomerESIMByOrder(_ context.Context, customerID, orderID string) (CustomerESIM, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, esim := range s.data.CustomerESIMs {
		if esim.CustomerID == customerID && esim.OrderID == orderID {
			return esim, nil
		}
	}
	return CustomerESIM{}, ErrCustomerESIMNotFound
}

func (s *FileStore) ListCustomerESIMs(_ context.Context, customerID string) ([]CustomerESIM, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := make([]CustomerESIM, 0)
	for _, esim := range s.data.CustomerESIMs {
		if esim.CustomerID == customerID {
			list = append(list, esim)
		}
	}
	sortCustomerESIMs(list)
	return list, nil
}

func sortCustomerESIMs(list []CustomerESIM) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && (list[j].CreatedAt.After(list[j-1].CreatedAt) ||
			(list[j].CreatedAt.Equal(list[j-1].CreatedAt) && list[j].ICCID > list[j-1].ICCID)); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

func (s *FileStore) UpdateCustomerESIMUsage(_ context.Context, iccid string, usage CustomerESIMUsage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	esim, ok := s.data.CustomerESIMs[iccid]
	if !ok {
		return ErrCustomerESIMNotFound
	}
	previous := esim
	now := s.clock.Now()
	esim.UsageStatus, esim.RemainingMB, esim.TotalMB, esim.ExpiresAt = usage.Status, usage.RemainingMB, usage.TotalMB, usage.ExpiresAt
	esim.UsageAt, esim.UpdatedAt = &now, now
	s.data.CustomerESIMs[iccid] = esim
	if err := s.saveLocked(); err != nil {
		s.data.CustomerESIMs[iccid] = previous
		return err
	}
	return nil
}

func (s *FileStore) RenameCustomerESIM(_ context.Context, customerID, iccid, label string) (CustomerESIM, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	esim, ok := s.data.CustomerESIMs[iccid]
	if !ok || esim.CustomerID != customerID {
		return CustomerESIM{}, ErrCustomerESIMNotFound
	}
	previous := esim
	esim.Label, esim.UpdatedAt = normalizeCustomerESIMLabel(label), s.clock.Now()
	s.data.CustomerESIMs[iccid] = esim
	if err := s.saveLocked(); err != nil {
		s.data.CustomerESIMs[iccid] = previous
		return CustomerESIM{}, err
	}
	return esim, nil
}

func (s *FileStore) ClaimCustomerESIMNotice(_ context.Context, iccid, level, packageName string) (bool, error) {
	key := customerESIMNoticeKey(iccid, level, packageName)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, seen := s.data.CustomerESIMNotices[key]; seen {
		return false, nil
	}
	if s.data.CustomerESIMNotices == nil {
		s.data.CustomerESIMNotices = map[string]time.Time{}
	}
	s.data.CustomerESIMNotices[key] = s.clock.Now()
	if err := s.saveLocked(); err != nil {
		delete(s.data.CustomerESIMNotices, key)
		return false, err
	}
	return true, nil
}

func (s *FileStore) ClearCustomerESIMNotices(_ context.Context, iccid string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for key := range s.data.CustomerESIMNotices {
		if strings.HasPrefix(key, iccid+"\x00") {
			delete(s.data.CustomerESIMNotices, key)
		}
	}
	return s.saveLocked()
}

func (s *FileStore) ForgetCustomerESIMs(_ context.Context, customerID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for iccid, esim := range s.data.CustomerESIMs {
		if esim.CustomerID != customerID {
			continue
		}
		delete(s.data.CustomerESIMs, iccid)
		for key := range s.data.CustomerESIMNotices {
			if strings.HasPrefix(key, iccid+"\x00") {
				delete(s.data.CustomerESIMNotices, key)
			}
		}
	}
	return s.saveLocked()
}

func (s *FileStore) ESIMCatalogVersion(_ context.Context) (string, time.Time, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.ESIMCatalog == nil {
		return "", time.Time{}, nil
	}
	return s.data.ESIMCatalog.Version, s.data.ESIMCatalog.SyncedAt, nil
}

func (s *FileStore) ReadESIMCatalog(_ context.Context) (ESIMCatalogDocument, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.ESIMCatalog == nil {
		return ESIMCatalogDocument{}, nil
	}
	return *s.data.ESIMCatalog, nil
}

func (s *FileStore) SaveESIMCatalog(_ context.Context, catalog ESIMCatalogDocument) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.data.ESIMCatalog
	s.data.ESIMCatalog = &catalog
	if err := s.saveLocked(); err != nil {
		s.data.ESIMCatalog = previous
		return err
	}
	return nil
}

// --- Postgres --------------------------------------------------------------

const customerESIMColumns = `iccid, customer_id, order_id, package_id, title, data, days, operator,
	destination, destination_name, country, image, unlimited, rechargeable, label, gift, simulated, test_mode,
	usage_status, remaining_mb, total_mb, expires_at, usage_at, created_at, updated_at`

func scanCustomerESIM(row pgx.Row) (CustomerESIM, error) {
	var esim CustomerESIM
	err := row.Scan(&esim.ICCID, &esim.CustomerID, &esim.OrderID, &esim.PackageID, &esim.Title, &esim.Data,
		&esim.Days, &esim.Operator, &esim.Destination, &esim.DestinationName, &esim.Country, &esim.Image, &esim.Unlimited,
		&esim.Rechargeable, &esim.Label, &esim.Gift, &esim.Simulated, &esim.TestMode, &esim.UsageStatus,
		&esim.RemainingMB, &esim.TotalMB, &esim.ExpiresAt, &esim.UsageAt, &esim.CreatedAt, &esim.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerESIM{}, ErrCustomerESIMNotFound
	}
	return esim, err
}

func (s *PostgresStore) SaveCustomerESIM(ctx context.Context, esim CustomerESIM) (CustomerESIM, error) {
	esim.ICCID = strings.TrimSpace(esim.ICCID)
	if esim.ICCID == "" || esim.CustomerID == "" {
		return CustomerESIM{}, errors.New("a customer esim needs an iccid and a customer")
	}
	now := s.clock.Now()
	if _, err := s.pool.Exec(ctx, `
INSERT INTO relay_customer_esims (iccid, customer_id, order_id, package_id, title, data, days, operator,
	destination, destination_name, country, image, unlimited, rechargeable, label, gift, simulated, test_mode,
	created_at, updated_at)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$19)
ON CONFLICT (iccid) DO NOTHING`,
		esim.ICCID, esim.CustomerID, esim.OrderID, esim.PackageID, esim.Title, esim.Data, esim.Days, esim.Operator,
		esim.Destination, esim.DestinationName, esim.Country, esim.Image, esim.Unlimited, esim.Rechargeable,
		normalizeCustomerESIMLabel(esim.Label), esim.Gift, esim.Simulated, esim.TestMode, now); err != nil {
		return CustomerESIM{}, err
	}
	return s.GetCustomerESIM(ctx, esim.ICCID)
}

func (s *PostgresStore) GetCustomerESIM(ctx context.Context, iccid string) (CustomerESIM, error) {
	return scanCustomerESIM(s.pool.QueryRow(ctx,
		`SELECT `+customerESIMColumns+` FROM relay_customer_esims WHERE iccid = $1`, strings.TrimSpace(iccid)))
}

func (s *PostgresStore) CustomerESIMByOrder(ctx context.Context, customerID, orderID string) (CustomerESIM, error) {
	return scanCustomerESIM(s.pool.QueryRow(ctx,
		`SELECT `+customerESIMColumns+` FROM relay_customer_esims WHERE customer_id = $1 AND order_id = $2`, customerID, orderID))
}

func (s *PostgresStore) ListCustomerESIMs(ctx context.Context, customerID string) ([]CustomerESIM, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+customerESIMColumns+` FROM relay_customer_esims
WHERE customer_id = $1 ORDER BY created_at DESC, iccid DESC`, customerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := make([]CustomerESIM, 0)
	for rows.Next() {
		esim, err := scanCustomerESIM(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, esim)
	}
	return list, rows.Err()
}

func (s *PostgresStore) UpdateCustomerESIMUsage(ctx context.Context, iccid string, usage CustomerESIMUsage) error {
	now := s.clock.Now()
	tag, err := s.pool.Exec(ctx, `UPDATE relay_customer_esims SET usage_status = $2, remaining_mb = $3, total_mb = $4,
	expires_at = $5, usage_at = $6, updated_at = $6 WHERE iccid = $1`,
		iccid, usage.Status, usage.RemainingMB, usage.TotalMB, usage.ExpiresAt, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrCustomerESIMNotFound
	}
	return nil
}

func (s *PostgresStore) RenameCustomerESIM(ctx context.Context, customerID, iccid, label string) (CustomerESIM, error) {
	return scanCustomerESIM(s.pool.QueryRow(ctx, `UPDATE relay_customer_esims SET label = $3, updated_at = $4
WHERE iccid = $1 AND customer_id = $2 RETURNING `+customerESIMColumns,
		iccid, customerID, normalizeCustomerESIMLabel(label), s.clock.Now()))
}

func (s *PostgresStore) ClaimCustomerESIMNotice(ctx context.Context, iccid, level, packageName string) (bool, error) {
	tag, err := s.pool.Exec(ctx, `INSERT INTO relay_customer_esim_notices (iccid, level, package_name, sent_at)
VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING`, iccid, level, packageName, s.clock.Now())
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *PostgresStore) ClearCustomerESIMNotices(ctx context.Context, iccid string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM relay_customer_esim_notices WHERE iccid = $1`, iccid)
	return err
}

func (s *PostgresStore) ForgetCustomerESIMs(ctx context.Context, customerID string) error {
	// The notices go with their eSIM (ON DELETE CASCADE).
	_, err := s.pool.Exec(ctx, `DELETE FROM relay_customer_esims WHERE customer_id = $1`, customerID)
	return err
}

func (s *PostgresStore) ESIMCatalogVersion(ctx context.Context) (string, time.Time, error) {
	var version string
	var syncedAt time.Time
	err := s.pool.QueryRow(ctx, `SELECT version, synced_at FROM relay_esim_catalog WHERE id = 1`).Scan(&version, &syncedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", time.Time{}, nil
	}
	return version, syncedAt, err
}

func (s *PostgresStore) ReadESIMCatalog(ctx context.Context) (ESIMCatalogDocument, error) {
	var catalog ESIMCatalogDocument
	err := s.pool.QueryRow(ctx, `SELECT version, document, synced_at FROM relay_esim_catalog WHERE id = 1`).
		Scan(&catalog.Version, &catalog.Document, &catalog.SyncedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ESIMCatalogDocument{}, nil
	}
	return catalog, err
}

func (s *PostgresStore) SaveESIMCatalog(ctx context.Context, catalog ESIMCatalogDocument) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO relay_esim_catalog (id, version, document, synced_at) VALUES (1,$1,$2,$3)
ON CONFLICT (id) DO UPDATE SET version = EXCLUDED.version, document = EXCLUDED.document, synced_at = EXCLUDED.synced_at`,
		catalog.Version, catalog.Document, catalog.SyncedAt)
	return err
}

// --- the cached store forwards it all ---------------------------------------

func (s *CachedInstallationStore) customerESIMStore() (CustomerESIMStore, error) {
	store, ok := s.store.(CustomerESIMStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) SaveCustomerESIM(ctx context.Context, esim CustomerESIM) (CustomerESIM, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return CustomerESIM{}, err
	}
	return store.SaveCustomerESIM(ctx, esim)
}

func (s *CachedInstallationStore) GetCustomerESIM(ctx context.Context, iccid string) (CustomerESIM, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return CustomerESIM{}, err
	}
	return store.GetCustomerESIM(ctx, iccid)
}

func (s *CachedInstallationStore) CustomerESIMByOrder(ctx context.Context, customerID, orderID string) (CustomerESIM, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return CustomerESIM{}, err
	}
	return store.CustomerESIMByOrder(ctx, customerID, orderID)
}

func (s *CachedInstallationStore) ListCustomerESIMs(ctx context.Context, customerID string) ([]CustomerESIM, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return nil, err
	}
	return store.ListCustomerESIMs(ctx, customerID)
}

func (s *CachedInstallationStore) UpdateCustomerESIMUsage(ctx context.Context, iccid string, usage CustomerESIMUsage) error {
	store, err := s.customerESIMStore()
	if err != nil {
		return err
	}
	return store.UpdateCustomerESIMUsage(ctx, iccid, usage)
}

func (s *CachedInstallationStore) RenameCustomerESIM(ctx context.Context, customerID, iccid, label string) (CustomerESIM, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return CustomerESIM{}, err
	}
	return store.RenameCustomerESIM(ctx, customerID, iccid, label)
}

func (s *CachedInstallationStore) ClaimCustomerESIMNotice(ctx context.Context, iccid, level, packageName string) (bool, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return false, err
	}
	return store.ClaimCustomerESIMNotice(ctx, iccid, level, packageName)
}

func (s *CachedInstallationStore) ClearCustomerESIMNotices(ctx context.Context, iccid string) error {
	store, err := s.customerESIMStore()
	if err != nil {
		return err
	}
	return store.ClearCustomerESIMNotices(ctx, iccid)
}

func (s *CachedInstallationStore) ForgetCustomerESIMs(ctx context.Context, customerID string) error {
	store, err := s.customerESIMStore()
	if err != nil {
		return err
	}
	return store.ForgetCustomerESIMs(ctx, customerID)
}

func (s *CachedInstallationStore) ESIMCatalogVersion(ctx context.Context) (string, time.Time, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return "", time.Time{}, err
	}
	return store.ESIMCatalogVersion(ctx)
}

func (s *CachedInstallationStore) ReadESIMCatalog(ctx context.Context) (ESIMCatalogDocument, error) {
	store, err := s.customerESIMStore()
	if err != nil {
		return ESIMCatalogDocument{}, err
	}
	return store.ReadESIMCatalog(ctx)
}

func (s *CachedInstallationStore) SaveESIMCatalog(ctx context.Context, catalog ESIMCatalogDocument) error {
	store, err := s.customerESIMStore()
	if err != nil {
		return err
	}
	return store.SaveESIMCatalog(ctx, catalog)
}
