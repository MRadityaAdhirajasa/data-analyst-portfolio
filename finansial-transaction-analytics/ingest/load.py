"""Load the raw financial-transaction dataset into the `staging` schema.

    uv run python ingest/load.py

Every column lands as TEXT. Casting happens in sql/01_staging.sql so a single
malformed value fails at a visible, fixable step instead of aborting a
13-million-row load. Re-running is safe: each table is truncated first.
"""

import json
import os
import pathlib
import sys
import time

import psycopg

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

DDL = """
CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.raw_transactions (
    id TEXT, date TEXT, client_id TEXT, card_id TEXT, amount TEXT,
    use_chip TEXT, merchant_id TEXT, merchant_city TEXT, merchant_state TEXT,
    zip TEXT, mcc TEXT, errors TEXT
);
CREATE TABLE IF NOT EXISTS staging.raw_users (
    id TEXT, current_age TEXT, retirement_age TEXT, birth_year TEXT,
    birth_month TEXT, gender TEXT, address TEXT, latitude TEXT, longitude TEXT,
    per_capita_income TEXT, yearly_income TEXT, total_debt TEXT,
    credit_score TEXT, num_credit_cards TEXT
);
-- card_number, cvv and year_pin_last_changed are dropped at load time:
-- no analysis uses them and this repository is public.
CREATE TABLE IF NOT EXISTS staging.raw_cards (
    id TEXT, client_id TEXT, card_brand TEXT, card_type TEXT,
    expires TEXT, has_chip TEXT, num_cards_issued TEXT, credit_limit TEXT,
    acct_open_date TEXT, card_on_dark_web TEXT
);
CREATE TABLE IF NOT EXISTS staging.raw_mcc (
    mcc TEXT, description TEXT
);
CREATE TABLE IF NOT EXISTS staging.raw_fraud_labels (
    transaction_id TEXT, is_fraud TEXT
);
"""

# (table, file, expected rows). Row counts are from the published dataset;
# a mismatch means the file is truncated or the wrong one.
CSV_SOURCES = [
    ("staging.raw_users", "users_data.csv", 2_000),
    ("staging.raw_cards", "cards_data.csv", 6_146),
    ("staging.raw_transactions", "transactions_data.csv", 13_305_915),
]

# cards_data.csv column order -> the subset we keep, by name.
CARD_KEEP = [
    "id", "client_id", "card_brand", "card_type", "expires", "has_chip",
    "num_cards_issued", "credit_limit", "acct_open_date", "card_on_dark_web",
]


def dsn():
    """Connection settings from .env, overridable by real environment vars."""
    cfg = {}
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    cfg.update({k: v for k, v in os.environ.items() if k in cfg})

    pw = cfg.get("POSTGRES_PASSWORD")
    if not pw or pw == "change_me":
        sys.exit("Set POSTGRES_PASSWORD in .env (copy .env.example).")
    return (
        f"host={cfg.get('PGHOST', 'localhost')} port={cfg.get('PGPORT', 5433)} "
        f"dbname={cfg.get('POSTGRES_DB', 'finance')} "
        f"user={cfg.get('POSTGRES_USER', 'analyst')} password={pw}"
    )


def copy_csv(cur, table, path, columns=None):
    """Stream a CSV file straight into `table` via COPY.

    ponytail: raw byte passthrough, 4 MB at a time. The transactions file is
    1.2 GB -- parsing it in Python first would be slower and would put the
    whole thing in RAM for no gain, since every column lands as TEXT anyway.
    """
    cols = f" ({', '.join(columns)})" if columns else ""
    stmt = f"COPY {table}{cols} FROM STDIN WITH (FORMAT csv, HEADER true)"
    size = path.stat().st_size
    done = 0
    with open(path, "rb") as fh, cur.copy(stmt) as copy:
        while chunk := fh.read(4 << 20):
            copy.write(chunk)
            done += len(chunk)
            if sys.stdout.isatty():   # a \r progress line is noise in a log
                print(f"  {path.name}: {done / size:5.1%}", end="\r", flush=True)


def copy_card_subset(cur, path):
    """cards_data.csv carries card_number/cvv/year_pin_last_changed.

    Those never reach the database. Dropping them here rather than in SQL
    means they are never written to disk at all.
    """
    import csv

    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        with cur.copy(
            f"COPY staging.raw_cards ({', '.join(CARD_KEEP)}) FROM STDIN"
        ) as copy:
            for row in reader:
                copy.write_row([row[c] for c in CARD_KEEP])


def copy_mcc(cur, path):
    codes = json.loads(path.read_text(encoding="utf-8"))
    with cur.copy("COPY staging.raw_mcc (mcc, description) FROM STDIN") as copy:
        for code, description in codes.items():
            copy.write_row([code, description])
    return len(codes)


def copy_fraud_labels(cur, path):
    """8.9 million labels -- 67% of transactions, sampled at random.

    The uncovered 33% is why the fact table carries has_fraud_label: any
    fraud rate must divide by labelled rows only.
    """
    labels = json.loads(path.read_text(encoding="utf-8"))["target"]
    with cur.copy(
        "COPY staging.raw_fraud_labels (transaction_id, is_fraud) FROM STDIN"
    ) as copy:
        for txn_id, flag in labels.items():
            copy.write_row([txn_id, flag])
    return len(labels)


def main():
    started = time.time()
    with psycopg.connect(dsn(), autocommit=False) as conn, conn.cursor() as cur:
        cur.execute(DDL)

        loaded = {}

        for table, filename, expected in CSV_SOURCES:
            path = DATA / filename
            if not path.exists():
                sys.exit(f"Missing {path}. Download the dataset into data/ first.")
            cur.execute(f"TRUNCATE {table};")
            t0 = time.time()
            if table == "staging.raw_cards":
                copy_card_subset(cur, path)
            else:
                copy_csv(cur, table, path)
            cur.execute(f"SELECT COUNT(*) FROM {table};")
            loaded[table] = (cur.fetchone()[0], expected)
            print(f"  {filename}: {loaded[table][0]:>12,} rows  "
                  f"({time.time() - t0:.1f}s)")

        cur.execute("TRUNCATE staging.raw_mcc;")
        n = copy_mcc(cur, DATA / "mcc_codes.json")
        cur.execute("SELECT COUNT(*) FROM staging.raw_mcc;")
        loaded["staging.raw_mcc"] = (cur.fetchone()[0], n)
        print(f"  mcc_codes.json: {loaded['staging.raw_mcc'][0]:>10,} rows")

        cur.execute("TRUNCATE staging.raw_fraud_labels;")
        t0 = time.time()
        n = copy_fraud_labels(cur, DATA / "train_fraud_labels.json")
        cur.execute("SELECT COUNT(*) FROM staging.raw_fraud_labels;")
        loaded["staging.raw_fraud_labels"] = (cur.fetchone()[0], 8_914_963)
        print(f"  train_fraud_labels.json: {loaded['staging.raw_fraud_labels'][0]:>12,} "
              f"rows ({time.time() - t0:.1f}s)")

        bad = [f"{t}: got {got:,}, expected {exp:,}"
               for t, (got, exp) in loaded.items() if got != exp]
        if bad:
            conn.rollback()
            sys.exit("Row count mismatch, rolled back: " + "; ".join(bad))

        conn.commit()

    total = sum(g for g, _ in loaded.values())
    print(f"\n{total:,} rows loaded in {time.time() - started:.0f}s. "
          f"All row counts match.\nNext: sql/01_staging.sql")


if __name__ == "__main__":
    main()
