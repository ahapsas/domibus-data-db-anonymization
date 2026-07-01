# Domibus e-Delivery Database Anonymization Pipeline

An enterprise-grade, data-driven anonymization engine built to mask sensitive production data inside the official European Commission Domibus 5.0.8 (e-Delivery) Oracle Database schema. Designed to be completely adaptive, this pipeline maintains compatibility up to version 5.1.9.

## Features
* **Dockerized Dual Environments**: Spins up two isolated Oracle Database 23ai Free containers representing a mock Production container (`domibus_prod_db`) and a secure Sandbox container (`domibus_anon_db`).
* **Dynamic Masking Engine**: Powered completely by a Python execution script driven by a `mapping.json` configuration file, eliminating brittle, hardcoded SQL scripts.
* **Advanced Masking & Speed**: Utilizes the high-performance `oracledb` Thin Driver to perform rapid relational array bulk updates. Supports deterministic updates, structural alphanumeric random string generation, background scheduler trimming, and binary payload (BLOB) wiping.

---

## System Architecture

The pipeline isolates data operations across two independent database environments to prevent any accidental leakage or mutation of raw production rows:

```text
[Production DB: Port 1521] ──(expdp data pump)──> [Host File System] ──(impdp target)──> [Sandbox DB: Port 1522] ──(anonymizer.py)──> [Safe Test Data]
```
>   **CI/CD Automation Ready**: This pipeline is built to be easily integrated into orchestration tools like **Jenkins, GitLab CI, or GitHub Actions**. You can schedule it as a weekly cron job to automatically tear down, refresh, and mask the database, ensuring your testing and QA teams always start their week with fresh, production-like, but completely anonymized data.

## Structure

```text
domibus-data-db-anonymization/
├── .venv/                          # Python virtual environment containing 'oracledb'
├── scripts/                        # Base Domibus SQL installation schemas
│   ├── 01_oracle-5.0.8.sql         # Domibus 5.0.8 version from https://tinyurl.com/3dc3j2fr
│   ├── 02_oracle-5.0.8-data.sql
│   └── 03_oracle-5.0.8-partitioning.sql
├── docker-compose.yml              # Oracle 23ai Express / Free containers configuration / PROD & ANON DB
├── .env                            # Core environment variables configuration (HOURS_TO_SYNC, passwords)
├── mapping.json                    # Custom anonymization mapping profiles (No-Code Config)
├── anonymizer.py                   # Dynamic Python Engine executing bulk updates & masking
└── run_pipeline.sh                 # Master Orchestrator (Dynamic Par-file setup, Expdp/Impdp, Python trigger)
```

## General

###  Domibus

Domibus is the sample implementation of an eDelivery AS4 Access Point maintained by the European Commission. It serves as a foundational building block for secure, reliable, and interoperable data exchange across digital borders in Europe. By providing a standardized gateway for electronic communication, Domibus enables public administrations, businesses, and organizations to connect effortlessly within the European single market.

Domibus is not just a software package; it is an enabler of cross-border digital integration. It provides a shared "language" and infrastructure for diverse IT systems. This eliminates the need for expensive, custom-built interfaces between different country networks.It powers critical European networks, including:e-Justice: For secure legal document exchange between courts.e-Health: For sharing medical records across borders safely.BRIS (Business Registers Interconnection System): For exchanging corporate data within the EU.

### The Need for Anonymization

Development and testing teams often require production-like data to thoroughly test and validate features. However, before a production database dump can be handed over to contractors or internal QA teams, it must be thoroughly anonymized.

The pipeline fulfills strict requirements regarding:

    - Compliance. Adherence to GDPR and data protection policies.
    - Security. Mitigation of data leakage vectors.
    - Data Sovereignty. Removing any corporate metadata that could reveal real business logic, partner details, endpoints, payloads, PModes, or EORIs.

To guarantee that the anonymized database remains fully functional for the application, the process adheres to the following constraints:

    - Format Integrity: Party IDs and identifiers maintain their required structures (e.g., system@EORI@MS). EORIs preserve the standard 2-letter country code + N-digit format.
    - Randomness & Consistency: Generated values are consistent within a specific record context but non-repeatable across different partners to prevent reverse-engineering.
    - Length Preservation: Masked values respect the column length definitions to avoid breaking UI layouts or validation constraints.
    - BLOB Anonymization: Heavy or sensitive XML/PDF payloads within BLOB columns are overwritten with non-sensitive dummy binary raw bytes while ensuring that the data container remains valid.

## The process

### Docker Container Initialization

We utilize the robust official gvenzl/oracle-free image. A key benefit of this image is its native initialization feature: any SQL script mounted inside the /container-entrypoint-initdb.d/ folder executes automatically upon container creation.

The docker-compose.yml configures:

    - sys password
    - the container names domibus_prod_db and domibus_anon_db
    - Volume mappings for initialization persistence.

You can monitor the database creation progress via: 
```text
docker logs -f domibus_prod_db 

```

### Database preparation

Download the official Domibus sql files from the https://ec.europa.eu/digital-building-blocks/sites/display/DIGITAL/Domibus+database+installation+and+upgrade+scripts . We will need the 3 files:

	- 01_oracle-5.0.8.sql 
	- 02_oracle-5.0.8-data.sql
	- 03_oracle-5.0.8-partitioning.sql

Note: The downloaded files must be renamed from .ddl to .sql and prefixed with numbers to enforce execution order. (for example the oracle-5.0.8.ddl should be 01_oracle-5.0.8.sql and should be executed first)

To route the objects out of the Root Container into the proper local pluggable scope, the scripts are enhanced with session-handling commands.

File 01_ should contain:

```text
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER DOMIBUS_ADMIN IDENTIFIED BY "DomibusPass123";
GRANT CREATE SESSION, ALTER SESSION, CONNECT, RESOURCE, DBA TO DOMIBUS_ADMIN;
ALTER USER DOMIBUS_ADMIN QUOTA UNLIMITED ON USERS;
ALTER SESSION SET CURRENT_SCHEMA = DOMIBUS_ADMIN;
```

and files 02_ and 03_

```text
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = DOMIBUS_ADMIN;
```

Testing the prod db with an external database manager should use these values (set port 1522 for the anon db the rest are the same): 

```text
    Host: localhost

    Port: 1521

    Database Type: Service Name

    Database (Name): FREEPDB1

    Username: DOMIBUS_ADMIN

    Password: DomibusPass123
```

## Metadata-Driven Anonymization Engine

The system operates on a metadata-driven approach. Anonymizer.py reads parsing rules out of mapping.json, dynamically builds optimized DML/DDL statements, and executes them over an active database transaction window.

This decouples the structural schema requirements from the pipeline logic, making it fully reusable across different environments or entirely separate database schemas.

## Quick Start
Start the database context:

```text   
   docker compose up -d
```

### Seed the environment

Import into prod db your real data. To populate the local testing container (`domibus_prod_db`) with raw data, use the provided `import.sh` utility. When executed, it will explicitly prompt you for three mandatory parameters: the local directory path of your dump file, the exact `.dmp` filename, and the original source schema name. It automatically transferring the export data into the Docker container, resetting the target `DOMIBUS_ADMIN` user, and performing the Oracle Data Pump import.

Note for Real Databases: If you want to run this pipeline against a real, external database instead of the local standalone Docker container, simply open run_pipeline.sh, and update the connection variables for the INT_SYS_PROD_SQL

### Run the Synchronized Masking Pipeline

Execute the master orchestrator to replicate active data partitions across the containers and mask the database sandbox records
```text

chmod +x run_pipeline.sh
./run_pipeline.sh
```

Note: To override the default sync window on-the-fly, declare the runtime variable directly before executing: HOURS_TO_SYNC=24 ./run_pipeline.sh . Remember the default sync window is one hour.