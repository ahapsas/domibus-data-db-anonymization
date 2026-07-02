# Domibus e-Delivery Database Anonymization Pipeline

An data-driven anonymization engine built, to anonymize sensitive production data inside the official European Commission Domibus 5.0.8 (e-Delivery) Oracle Database schema. Designed to be completely adaptive, this pipeline maintains compatibility up to version 5.1.9.

## Features
* **Dockerized Dual Environment**: Starts up two isolated Oracle Database 23 free containers representing a mock Production container (`domibus_prod_db`) and a secure Sandbox container (`domibus_anon_db`).
* **Dynamic Masking Engine**: A python script reads the `mapping.json` configuration file creating the right sql commands, eliminating  hardcoded SQL scripts.
* **Advanced Masking & Speed**: Uses the `oracledb` Thin Driver to perform rapid bulk updates. Supports deterministic updates, structural alphanumeric random string generation, and binary payload (BLOB) wiping.

---

## System Architecture

The pipeline isolates data operations across two independent database environments to prevent any accidental leakage or mutation of raw production rows:

```text
[Production DB: Port 1521] ──(expdp data pump)──> [Host File System] ──(impdp target)──> [Sandbox DB: Port 1522] ──(anonymizer.py)──> [Safe Test Data]
```
>   **CI/CD Intergration**: This pipeline can be intergrated into with tools like **Jenkins, GitLab CI, or GitHub Actions**. You can schedule it as a weekly cron job to automatically tear down, refresh, and mask the database, ensuring your testing and QA teams always have a fresh, production-like, but completely anonymized data schmema.

## Structure

```text
domibus-data-db-anonymization/
├── .venv/                                          # Python virtual environment containing 'oracledb'
├── .env                                            # Core environment variables configuration (HOURS_TO_SYNC, passwords)
├── anonymizer.py                                   # Python script that applies masking rules to the anonymized database
├── docker
│   ├── docker-compose.yml                          # Oracle 23 Express / Free container definitions for PROD and ANON DB
│   ├── exports                                     # Output folder for exported anonymized dump files
│   └── scripts                                     # Domibus 5.0.8 SQL installation scripts used to initialize the database
│       ├── 01_oracle-5.0.8.sql
│       ├── 02_oracle-5.0.8-data.sql
│       └── 03_oracle-5.0.8-partitioning.sql
├── LICENSE                                         # Project license
├── mapping.json                                    # Custom anonymization mapping profile used by anonymizer.py
├── README.md                                       # Project documentation
├── run_pipeline.sh                                 # Master orchestrator for export/import and masking workflow
├── scripts
│   ├── export.sh                                   # Utility to export the masked dump file from the anon database
│   └── import.sh                                   # Utility to import a dump file into the prod database container
└── validator.py                                    # Python script that generates a validation report
```

## General

### Domibus

Domibus is the sample implementation of an eDelivery AS4 Access Point maintained by the European Commission. It serves as a foundational building block for secure, reliable, and interoperable data exchange across digital borders in Europe. By providing a standardized gateway for electronic communication, Domibus enables public administrations, businesses, and organizations to connect effortlessly within the European single market.

Domibus is not just a software package; it is an enabler of cross-border digital integration. It provides a shared "language" and infrastructure for diverse IT systems. This eliminates the need for expensive, custom-built interfaces between different country networks.It powers critical European networks, including:e-Justice: For secure legal document exchange between courts.e-Health: For sharing medical records across borders safely.BRIS (Business Registers Interconnection System): For exchanging corporate data within the EU.

### The Need for Anonymization

Development and testing teams often require production-like data to thoroughly test and validate features. However, before a production database dump can be handed over to contractors or internal QA teams, it must be thoroughly anonymized and remove any sensitive information.

The pipeline fulfills strict requirements regarding:

    - Compliance. Adherence to GDPR and data protection policies.
    - Security. Mitigation of data leakage vectors.
    - Data Sovereignty. Removing any corporate metadata that could reveal real business logic, partner details, endpoints, payloads, PModes, or EORIs.

To guarantee that the anonymized database remains fully functional for the application, the process adheres to the following constraints:

    - Format Integrity: Party IDs and identifiers maintain their required structures (e.g., system@EORI@MS). EORIs preserve the standard 2-letter country code + N-digit format.
    - Randomness & Consistency: Generated values are consistent within a specific record context but non-repeatable across different partners to prevent reverse-engineering.
    - Length Preservation: Masked values respect the column length definitions to avoid breaking UI layouts or validation constraints.
    - BLOB Anonymization: Heavy or sensitive XML/PDF payloads within BLOB columns are overwritten with the text "ANONYMOUS" ensuring that the data container remains valid.

## The process

### Docker Container Initialization

We use the official gvenzl/oracle-free image. A key benefit of this image is its native initialization feature: any SQL script mounted inside the /container-entrypoint-initdb.d/ folder executes automatically upon container creation.

The docker-compose.yml configures:

    - sys password
    - the container names domibus_prod_db and domibus_anon_db
    - Volume mappings for initialization persistence.

You can monitor the database creation progress via: 
```text
docker logs -f domibus_prod_db 

```

### Database preparation

Download the official Domibus sql files from the https://ec.europa.eu/digital-building-blocks/sites/display/DIGITAL/Domibus+database+installation+and+upgrade+scripts . We will need the 3 files since it is supposed to fire up a new installation:

	- 01_oracle-5.0.8.sql 
	- 02_oracle-5.0.8-data.sql
	- 03_oracle-5.0.8-partitioning.sql

Note: The downloaded files must be renamed from .ddl to .sql and prefixed with numbers to enforce execution order. (for example the oracle-5.0.8.ddl should be 01_oracle-5.0.8.sql and should be executed first)

To route the objects out of the Root Container into the proper local pluggable scope, the scripts are enhanced with session-handling commands.

Script 01_ should contain:

```text
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER DOMIBUS_ADMIN IDENTIFIED BY "DomibusPass123";
GRANT CREATE SESSION, ALTER SESSION, CONNECT, RESOURCE, DBA TO DOMIBUS_ADMIN;
ALTER USER DOMIBUS_ADMIN QUOTA UNLIMITED ON USERS;
ALTER SESSION SET CURRENT_SCHEMA = DOMIBUS_ADMIN;
```

and scripts 02_ and 03_

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

Import into prod db your real data. To populate the local testing container (`domibus_prod_db`) with raw data, you can use the provided `import.sh` utility. When executed, it will explicitly prompt you for three mandatory parameters: the local directory path of your dump file, the exact `.dmp` filename, and the original source schema name. It automatically transferring the exported data into the Docker container, resetting the target `DOMIBUS_ADMIN` user, and performing the Oracle Data Pump import.

Note for Real Databases: If you want to run this pipeline against a real, external database instead of the local standalone Docker container, simply open run_pipeline.sh, and update the connection variables for the INT_SYS_PROD_SQL.

### Run the Synchronized Masking Pipeline

Execute the master orchestrator to replicate active data partitions across the containers and mask the database sandbox records
```text

chmod +x run_pipeline.sh
./run_pipeline.sh
```

Note: To override the default sync window on-the-fly, declare the runtime variable directly before executing: HOURS_TO_SYNC=24 ./run_pipeline.sh . Remember the default sync window is one hour.

### Anonymized dump file

To export the anonymized dump file, execute the `export.sh` script. The anonymized dump file will be written to the `exports` folder.

```text
chmod +x export.sh
./export.sh
```

### Validation report

You can run the validation script to generate an HTML report comparing the data state before and after anonymization.

```text
python validation.py
```