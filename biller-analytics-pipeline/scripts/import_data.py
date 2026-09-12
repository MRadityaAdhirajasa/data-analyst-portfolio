"""Load the biller transaction dataset into staging.raw_transactions.

Usage:
    export PGPASSWORD=yourpassword
    python scripts/import_data.py data/sample_transactions.csv

Accepts .csv (semicolon-delimited, as exported from the source workbook)
or .xlsx. Re-running is safe: the staging table is truncated first.
"""

import os
import sys
import time

import pandas as pd
import psycopg2
from psycopg2.extras import execute_values

DB = {
    "host": os.getenv("PGHOST", "localhost"),
    "port": int(os.getenv("PGPORT", 5432)),
    "dbname": os.getenv("PGDATABASE", "data_warehouse"),
    "user": os.getenv("PGUSER", "postgres"),
    "password": os.getenv("PGPASSWORD"),
}

# Source column order -> staging.raw_transactions column order
SOURCE_COLUMNS = [
    "ID Transaksi", "Tanggal", "No Rekening", "Nama Nasabah",
    "Jenis Biller", "Nama Biller", "Nomor Pelanggan",
    "Nominal", "Biaya Admin", "Total Bayar", "Channel", "Status",
]

DDL = """
CREATE SCHEMA IF NOT EXISTS staging;
CREATE TABLE IF NOT EXISTS staging.raw_transactions (
    id_transaksi        VARCHAR(20) PRIMARY KEY,
    tanggal             VARCHAR(20),
    no_rekening         BIGINT,
    nama_nasabah        VARCHAR(100),
    jenis_biller        VARCHAR(50),
    nama_biller         VARCHAR(50),
    nomor_pelanggan     BIGINT,
    nominal             BIGINT,
    biaya_admin         BIGINT,
    total_bayar         BIGINT,
    channel             VARCHAR(50),
    status              VARCHAR(20)
);
"""

INSERT = """
INSERT INTO staging.raw_transactions
    (id_transaksi, tanggal, no_rekening, nama_nasabah,
     jenis_biller, nama_biller, nomor_pelanggan,
     nominal, biaya_admin, total_bayar, channel, status)
VALUES %s
"""


def read_source(path):
    """Read the dataset from .csv (semicolon-delimited) or .xlsx."""
    if path.lower().endswith(".xlsx"):
        return pd.read_excel(path)
    return pd.read_csv(path, sep=";")


def main(path):
    start = time.time()
    df = read_source(path)
    print(f"Read {len(df):,} rows from {path} in {time.time() - start:.1f}s")

    missing = [c for c in SOURCE_COLUMNS if c not in df.columns]
    if missing:
        sys.exit(f"Source file is missing expected columns: {missing}")

    rows = [tuple(r) for r in df[SOURCE_COLUMNS].values]

    with psycopg2.connect(**DB) as conn, conn.cursor() as cur:
        cur.execute(DDL)
        cur.execute("TRUNCATE staging.raw_transactions;")

        start = time.time()
        # ponytail: 5k batches, tuned by hand. COPY is faster but this is
        # a one-shot load of 200k rows and finishes in seconds either way.
        batch_size = 5000
        for i in range(0, len(rows), batch_size):
            execute_values(cur, INSERT, rows[i:i + batch_size])
            print(f"  {min(i + batch_size, len(rows)):,}/{len(rows):,}", end="\r")

        cur.execute("SELECT COUNT(*) FROM staging.raw_transactions;")
        loaded = cur.fetchone()[0]

    print(f"\nLoaded {loaded:,} rows in {time.time() - start:.1f}s")
    assert loaded == len(df), f"Row count mismatch: read {len(df)}, loaded {loaded}"
    print("Row counts match. Next: psql -d data_warehouse -f sql/01_pipeline.sql")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if not DB["password"]:
        sys.exit("Set PGPASSWORD before running.")
    main(sys.argv[1])
