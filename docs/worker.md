# Migration worker · deploy

`supabase/worker/migration_worker.py` does the heavy loading. It runs on **its own small server**, in the same region as
the Supabase project (`xhsfkbbcejgwvqxpqdgq`). It never runs on Vercel or in the browser.

## Machine
- Small Linux VM or container (2 vCPU / 4 GB is enough for the test companies; give real exports more disk than the
  largest unpacked export).
- Python 3.11 with `psycopg[binary]`, `openpyxl`, `requests` — or use the Docker image below.

## Files beside the worker
- `supabase/worker/*` (this repo).
- `02_clean_blank_keys.sql`, `03_orphan_check.sql`, `04_foreign_keys.sql`, `04z_drop_foreign_keys.sql`, `06_security.sql`
  from the **sanford-db-install** package (not in this repo). Put them in `/opt/sanford/sql` and pass `--scripts`.

## Environment
| Variable | Value |
|---|---|
| `DATABASE_URL` | **Session pooler** (`postgres.<ref>@aws-0-ap-south-1.pooler.supabase.com:5432`, works over IPv4) or the direct connection — not the transaction pooler (6543). Read from the environment; never pass the password with `--dsn` (every process could read it) |
| `MIG_RESUMABLE` | `1` on the cloud worker (set in the Docker image): resumable mode, see below |
| `SUPABASE_ACCESS_TOKEN` | optional: lets the worker watch the database disk and stop before it is full |
| `SUPABASE_URL` | `https://xhsfkbbcejgwvqxpqdgq.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | the secret key — only on this server |

## Recommended: AWS Mumbai with one paste
See [hosting.md](hosting.md) and [`worker/cloud-init.yaml`](../worker/cloud-init.yaml).

## Option A · Docker (restart policy)
```bash
docker build -f worker/Dockerfile -t sanford-migration-worker .
docker run -d --name sanford-worker --restart unless-stopped \
  -e DATABASE_URL -e SUPABASE_URL -e SUPABASE_SERVICE_ROLE_KEY \
  -v /opt/sanford/sql:/opt/sanford/sql:ro sanford-migration-worker
docker logs -f sanford-worker
```

## Option B · systemd
`/etc/systemd/system/sanford-worker.service`
```ini
[Unit]
Description=Sanford ERP migration worker
After=network-online.target

[Service]
User=sanford
EnvironmentFile=/etc/sanford/worker.env
WorkingDirectory=/opt/sanford
ExecStart=/usr/bin/python3 /opt/sanford/worker/migration_worker.py --resumable --source storage --poll --scripts /opt/sanford/sql
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```
`sudo systemctl enable --now sanford-worker && journalctl -u sanford-worker -f`

## Before the first real load
- `max_locks_per_transaction` raised (see `docs/setup.md`), otherwise the rebuild fails with "out of shared memory".
## Resumable mode (`--resumable` / `MIG_RESUMABLE=1`)
- **cast** commits after every batch of 50 tables (`MIG_BATCH`). A re-run of the **same run** skips the tables already
  committed (read from `sap._load_log` of that run) and continues with the rest; `clean_02` → `cross_check` stay one transaction.
- A lost database connection, or a SIGTERM (`docker stop`, `update.sh`, reboot), **re-queues the run by itself**
  (warning issue `auto_resume_N`, at most `MIG_MAX_AUTO_RESUME` = 5); the poll loop reconnects and continues.
- Trade-off: after a failure the company keeps the raw rows loaded so far (not its previous ones), and the links dropped by
  04z stay dropped until the run finishes. Fine for the first load of an empty company; for a reload of a live company
  run without `--resumable` (all-or-nothing).

- One rebuild runs at a time (advisory lock). If the worker process dies, Postgres rolls the company back; the run stays
  in its running status — press **Stop run** in B7 (or re-queue).

