# Hosting decision (8 Nov 2026)

**Chosen: Option A — managed, closest region to the GCC.** Can be moved to an in-country cloud later (see "Moving later").

| Part | Where | Why |
|---|---|---|
| Web app | **Vercel** (served from its Dubai edge, `dxb1`, and worldwide) | Static app, no business data in it; auto-deploys from GitHub `main` |
| Database, logins, file storage, live updates | **Supabase, South Asia (Mumbai, `ap-south-1`)** | Supabase has no Middle East region; Mumbai is the closest (~30–40 ms from Dubai). Managed backups and patching |
| Migration worker | **AWS EC2, Mumbai (`ap-south-1`)**, Ubuntu 24.04, `t3.large`, 100 GB gp3 | Must sit next to the database: a rebuild is one long, heavy transaction. ~US\$70–90/month; can be stopped between migration waves |

## Setting up the worker (10 minutes, no SSH needed)
1. AWS console → region **Asia Pacific (Mumbai)** → EC2 → **Launch instance**.
2. Ubuntu Server 24.04 LTS · `t3.large` · 100 GB gp3 · security group with **no inbound rules** (the worker only connects out).
3. *Advanced details → User data*: paste [`worker/cloud-init.yaml`](../worker/cloud-init.yaml) after filling `<DB-PASSWORD>` and `<SUPABASE-SECRET-KEY>`.
4. Launch. After ~5 minutes the worker is polling; check with *EC2 → Connect → Session Manager*: `sudo journalctl -u sanford-worker -f`.
5. Update later: `sudo /opt/sanford/update.sh`.

The scripts the worker needs from the IT package (02, 03, 04, 04z, 06) are kept in the **private** Storage bucket `worker-assets`
(readable only with the secret key) and fetched on every start.

## Database setting still required
`max_locks_per_transaction` must be **2048** before a real load (now 64). Needs a Supabase access token
(`SUPABASE_ACCESS_TOKEN` in `.env.db`) or `npx supabase login` + `npx supabase postgres-config update --config max_locks_per_transaction=2048 --project-ref xhsfkbbcejgwvqxpqdgq --experimental`.

## Moving later (if data must stay in the UAE / KSA)
Self-host Supabase (Docker) on **AWS UAE `me-central-1`** (or Azure UAE North, Oracle Dubai/Jeddah, Google Dammam for KSA),
then: `pg_dump` → restore, copy Storage objects, point `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` in Vercel and the worker's
`.env` at the new host, move the worker into the same region. No app code changes.

## Security follow-ups
- The GitHub repository is **public**. It contains no secrets (checked), but it does contain the database design and worker
  code. Recommended: make it private (GitHub → Settings → General → Danger zone → Change visibility); Vercel keeps deploying.
- Rotate the Supabase secret key, database password and the three temporary login passwords (all appeared in chat).
