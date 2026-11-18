package chat

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	troupe "github.com/ShiningRay/troupe-go"
)

// SQLiteOutboxStore 在 troupe.SQLitePropStore 之上补齐 Outbox 合同
// （运行时侧 SQLite 暂无 Outbox 实现，与 ruby 版当年同构；参照 troupepg 的两表模式）：
//   - WriteWithOutbox 在**同一事务**内联 Props CAS（revision + epoch fencing 校验）+
//     journal upsert + outbox 插入 —— 事件与 Props 原子提交；
//   - PollOutbox 返回未投递事件；MarkSent 记入 sent 表（at-least-once：崩溃重投）。
//
// epoch/租约校验沿用 troupe SQLiteOwnershipStore 的语义：写仍要求
// `epoch` 与 ownership 表一致（单机多进程场景的防线与 troupego sqlite_store 一致）。
type SQLiteOutboxStore struct {
	*troupe.SQLitePropStore
	db  *sql.DB
	dsn string
}

// OpenSQLiteOutbox 打开 SQLite 存储并装饰 Outbox 合同（组合 OpenSQLite + 迁移）。
// outbox 侧自持一个与主 store 同 DSN 的单连接池（WAL 下并存安全，modernc/sqlite
// 单写者约束按连接各自限制 1）；Close 时两条连接一并关闭。
func OpenSQLiteOutbox(path string) (*SQLiteOutboxStore, *troupe.SQLiteOwnershipStore, error) {
	store, own, err := troupe.OpenSQLite(path)
	if err != nil {
		return nil, nil, err
	}
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		_ = store.Close()
		return nil, nil, fmt.Errorf("打开 SQLite outbox 连接失败：%w", err)
	}
	db.SetMaxOpenConns(1)
	s := &SQLiteOutboxStore{SQLitePropStore: store, db: db, dsn: dsn}
	s.migrate()
	return s, own, nil
}

// Close 关闭主 store 与 outbox 连接（Windows：不关句柄会占住文件）。
func (s *SQLiteOutboxStore) Close() error {
	errDb := s.db.Close()
	errStore := s.SQLitePropStore.Close()
	if errDb != nil {
		return errDb
	}
	return errStore
}

func (s *SQLiteOutboxStore) migrate() {
	for _, stmt := range []string{
		`CREATE TABLE IF NOT EXISTS troupe_outbox (
			actor_id TEXT NOT NULL,
			event_id TEXT NOT NULL,
			topic TEXT NOT NULL,
			payload TEXT NOT NULL DEFAULT 'null',
			created_at INTEGER NOT NULL,
			PRIMARY KEY (actor_id, event_id)
		)`,
		`CREATE TABLE IF NOT EXISTS troupe_outbox_sent (
			actor_id TEXT NOT NULL,
			event_id TEXT NOT NULL,
			sent_at INTEGER NOT NULL,
			PRIMARY KEY (actor_id, event_id)
		)`,
	} {
		if _, err := s.db.Exec(stmt); err != nil {
			panic(fmt.Sprintf("SQLite outbox 迁移失败：%v", err))
		}
	}
}

// WriteWithOutbox Props CAS + journal + outbox 同一事务原子提交。
// 语义与 troupepg 的 WriteWithOutbox 一致（复用 ownership epoch 校验）。
func (s *SQLiteOutboxStore) WriteWithOutbox(ctx context.Context, actorID troupe.ActorID,
	expectedRevision uint64, schemaVersion int, data string, epoch uint64,
	journal []troupe.IdempotencyRecord, outbox []troupe.OutboxRecord,
) (troupe.PropRecord, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return troupe.PropRecord{}, fmt.Errorf("SQLite 事务失败：%w", err)
	}
	defer func() { _ = tx.Rollback() }()

	canonical := actorID.Canonical()
	tag, err := tx.ExecContext(ctx,
		`UPDATE troupe_props
		 SET revision = revision + 1, schema_version = ?, data = ?, epoch = ?
		 WHERE actor_id = ? AND revision = ?
		   AND ? = (SELECT epoch FROM troupe_ownership WHERE actor_id = ?)`,
		schemaVersion, data, epoch, canonical, expectedRevision, epoch, canonical,
	)
	if err != nil {
		return troupe.PropRecord{}, fmt.Errorf("SQLite write 失败：%w", err)
	}
	if n, _ := tag.RowsAffected(); n == 0 {
		return troupe.PropRecord{}, &troupe.ConflictError{Kind: troupe.ConflictRevision, Actor: canonical}
	}
	for _, entry := range journal {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO troupe_journal (actor_id, key, fingerprint, ok, value, error_class, error_message, expires_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT (actor_id, key) DO UPDATE SET fingerprint = excluded.fingerprint, ok = excluded.ok,
			   value = excluded.value, error_class = excluded.error_class,
			   error_message = excluded.error_message, expires_at = excluded.expires_at`,
			canonical, entry.Key, entry.Fingerprint, entry.OK, entry.Value,
			entry.ErrorClass, entry.ErrorMessage, entry.ExpiresAt,
		); err != nil {
			return troupe.PropRecord{}, fmt.Errorf("SQLite journal 写失败：%w", err)
		}
	}
	for _, rec := range outbox {
		payload, err := compactJSON(rec.Payload)
		if err != nil {
			return troupe.PropRecord{}, fmt.Errorf("outbox 载荷序列化失败：%w", err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO troupe_outbox (actor_id, event_id, topic, payload, created_at)
			 VALUES (?, ?, ?, ?, ?)`,
			canonical, rec.EventID, rec.Topic, payload, rec.CreatedAt.UnixMilli(),
		); err != nil {
			return troupe.PropRecord{}, fmt.Errorf("SQLite outbox 写失败：%w", err)
		}
	}
	// 读取新 revision（与 writeCore 收尾一致）
	var revision, schema uint64
	if err := tx.QueryRowContext(ctx,
		`SELECT revision, schema_version FROM troupe_props WHERE actor_id = ?`, canonical,
	).Scan(&revision, &schema); err != nil {
		return troupe.PropRecord{}, fmt.Errorf("SQLite 回读失败：%w", err)
	}
	if err := tx.Commit(); err != nil {
		return troupe.PropRecord{}, fmt.Errorf("SQLite 提交失败：%w", err)
	}
	return troupe.PropRecord{Revision: revision, SchemaVersion: int(schema), Data: data, Epoch: epoch}, nil
}

// PollOutbox 返回该 actor 的未投递事件（派发器轮询；MarkSent 后不再返回）。
func (s *SQLiteOutboxStore) PollOutbox(ctx context.Context, actorID troupe.ActorID, limit int) ([]troupe.OutboxRecord, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT event_id, topic, payload, created_at FROM troupe_outbox
		 WHERE actor_id = ?
		   AND event_id NOT IN (SELECT event_id FROM troupe_outbox_sent WHERE actor_id = ?)
		 ORDER BY created_at, rowid LIMIT ?`,
		actorID.Canonical(), actorID.Canonical(), limit,
	)
	if err != nil {
		return nil, fmt.Errorf("SQLite outbox 轮询失败：%w", err)
	}
	defer rows.Close()
	var out []troupe.OutboxRecord
	for rows.Next() {
		var rec troupe.OutboxRecord
		var payload string
		var createdAt int64
		if err := rows.Scan(&rec.EventID, &rec.Topic, &payload, &createdAt); err != nil {
			return nil, fmt.Errorf("SQLite outbox 行读取失败：%w", err)
		}
		rec.ActorID = actorID.Canonical()
		rec.Payload = json.RawMessage(payload)
		rec.CreatedAt = time.UnixMilli(createdAt)
		out = append(out, rec)
	}
	return out, rows.Err()
}

// MarkSent 标记已投递（返回是否本次生效；重复标记幂等）。
func (s *SQLiteOutboxStore) MarkSent(ctx context.Context, actorID troupe.ActorID, eventID string) bool {
	res, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO troupe_outbox_sent (actor_id, event_id, sent_at) VALUES (?, ?, ?)`,
		actorID.Canonical(), eventID, time.Now().UTC().UnixMilli(),
	)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n > 0
}

func compactJSON(raw json.RawMessage) (string, error) {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return "", err
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
