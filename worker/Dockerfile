# Sanford ERP migration worker
# Runs migration_worker.py next to the Supabase database. Never on Vercel, never in the browser.
#
# Build (from the repo root):
#   docker build -f worker/Dockerfile -t sanford-migration-worker .
# Run (the 02/03/04/04z/06 scripts from the sanford-db-install package are mounted at /opt/sanford/sql):
#   docker run -d --name sanford-worker --restart unless-stopped \
#     -e DATABASE_URL="postgresql://postgres.<ref>:<password>@aws-0-ap-south-1.pooler.supabase.com:5432/postgres" \
#     -e SUPABASE_URL="https://<ref>.supabase.co" -e SUPABASE_SERVICE_ROLE_KEY="<secret key>" \
#     -v /opt/sanford/sql:/opt/sanford/sql:ro sanford-migration-worker

FROM python:3.11-slim

# MIG_RESUMABLE=1: cast commits after every batch of 50 tables and a re-run continues where it stopped; a lost
# connection re-queues the run by itself.
ENV PYTHONUNBUFFERED=1 \
    MIG_RESUMABLE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install "psycopg[binary]" openpyxl requests \
 && useradd --create-home --uid 10001 worker \
 && mkdir -p /opt/sanford/sql /work \
 && chown worker:worker /work

WORKDIR /app
COPY supabase/worker/ /app/

USER worker
WORKDIR /work

# Logs go to stdout. DATABASE_URL (session pooler or direct connection, port 5432 - not the transaction pooler) is read
# from the environment, never put on the command line, where every process on the machine could read the password.
CMD ["python", "/app/migration_worker.py", "--source", "storage", "--poll", "--scripts", "/opt/sanford/sql", "--workdir", "/work"]
