# Domibus e-Delivery Database Anonymization Pipeline

An data-driven anonymization engine built, to anonymize sensitive production data inside the official European Commission Domibus 5.0.8 (e-Delivery) Oracle Database schema. Designed to be completely adaptive, this pipeline maintains compatibility up to version 5.1.9.

## Features
**Dockerized Dual Environment**: Starts up two isolated Oracle Database 23 Free containers representing a mock Production container (`domibus_prod_db`) and a secure Sandbox container (`domibus_anon_db`).
* **Fully Automated Initialization**: Automatically provisions the `DOMIBUS_ADMIN` user, schemas, and table structures out-of-the-box via mounted initialization scripts on first boot.
* **Dynamic Masking Engine**: A Python script reads the `mapping.json` configuration file, dynamically creating the right SQL commands and eliminating hardcoded scripts.
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
├── anonymizer.py                                   # Python script that applies masking rules to the anonymized database
├── app.py                                          # Flask backend API serving the web dashboard
├── Diagram.png                                     # Architecture diagram showing the data flow and container layout
├── docker-compose.yml                              # Oracle Free container definitions for PROD and ANON DB, plus Nginx & API
├── Dockerfile                                      # Container definition for the Flask API and Python environment
├── export.sh                                       # Utility to export the masked dump file from the anon database
├── exports/                                        # Output folder for exported anonymized dump files
├── import.sh                                       # Utility to import a dump file into the container via Data Pump
├── index.html                                      # Web dashboard interface for triggering the pipeline
├── LICENSE                                         # Project license
├── mapping.json                                    # Custom anonymization mapping profile used by anonymizer.py
├── nginx.conf                                      # Nginx reverse proxy configuration for the web UI and API
├── README.md                                       # Project documentation
├── run_pipeline.sh                                 # Master orchestrator for export/import and masking workflow
├── scripts/                                        # Pure SQL installation and initialization Domibus scripts executed automatically on container boot
│   ├── 01_oracle-5.0.8.sql
│   ├── 02_oracle-5.0.8-data.sql
│   ├── 03_oracle-5.0.8-partitioning.sql
│   └── 04_init_domibus.sql                         # Automatically provisions the DOMIBUS_ADMIN user and permissions
├── validation_report.html                          # Generated HTML validation report comparing data states
└── validator.py                                    # Python script that generates the validation report
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
    - Volume mappings for initialization persistence and Data Pump directory access (./exports).

You can monitor the database creation progress via: 
```text
docker logs -f domibus_prod_db 

```

### Database preparation

Download the official Domibus sql files from the https://ec.europa.eu/digital-building-blocks/sites/display/DIGITAL/Domibus+database+installation+and+upgrade+scripts . We will need the 3 files since it is supposed to fire up a new installation:

	- 01_oracle-5.0.8.sql 
	- 02_oracle-5.0.8-data.sql
	- 03_oracle-5.0.8-partitioning.sql

Note: The downloaded files must be renamed from .ddl to .sql and prefixed with numbers to enforce execution order. (for example the original oracle-5.0.8.ddl file should be renamed to 01_oracle-5.0.8.sql and should be executed first)

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
A dedicated automated initialization script (04_init_domibus.sql) is included in the scripts/ directory to seamlessly guarantee that DOMIBUS_ADMIN and permissions are set up on first boot.

## Configuration (`.env`)

Create a `.env` file in the root directory of the project based on the following template. This file configures both the production and anonymization sandbox database connections and container hostnames.

```env
# Database Credentials & Core Settings
DB_USER=DOMIBUS_ADMIN
DB_PASS=DomibusPass123
PDB_NAME=FREEPDB1

# Sync & Port Configuration
HOURS_TO_SYNC=1
ANON_PORT=1522

# Docker Internal Network Hosts (Required for containerized execution)
PROD_DB_HOST=domibus_prod_db
ANON_DB_HOST=domibus_anon_db
```
### Variable Reference:

* DB_USER: The Oracle schema user (default: DOMIBUS_ADMIN).
* DB_PASS: Password for the database schema.
* PDB_NAME: The Oracle Pluggable Database name (e.g., FREEPDB1).
* PROD_DB_HOST / ANON_DB_HOST: Docker Compose service names used by internal Python scripts and validation tools to route traffic across containers.

## Metadata-Driven Anonymization Engine

The system operates on a metadata-driven approach. Anonymizer.py reads parsing rules out of mapping.json, dynamically builds optimized DML/DDL statements, and executes them over an active database transaction window.

This decouples the structural schema requirements from the pipeline logic, making it fully reusable across different environments or entirely separate database schemas.

## Quick Start
Start the database and API context:

```text   
   docker compose up -d --build
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

Note: To override the default sync window on-the-fly, declare the runtime variable directly before executing: 
```text
HOURS_TO_SYNC=24 ./run_pipeline.sh . 
```
Remember the default sync window is one hour.

### Anonymized dump file

To export the anonymized dump file, execute the `export.sh` script. The anonymized dump file will be written to the `exports` folder.

```text
chmod +x export.sh
./export.sh
```

### Validation report

You can run the validation script to generate an HTML report comparing the data state before and after anonymization.

```text
docker compose exec api python3 validator.py
```

---

## Web UI & REST API Dashboard

The pipeline features an integrated lightweight web dashboard served via **Nginx** and powered by a **Flask API backend** (`app.py`), enabling zero-touch execution directly from your browser.

### Architecture & Routing
* **Web UI (`index.html`)**: Served on port `8080`, providing a clean control center with an interactive trigger button and direct report access.
* **Nginx Reverse Proxy (`nginx.conf`)**: Directs HTTP traffic, routing UI requests cleanly to the backend services.
* **Flask API (`app.py`)**: Listens on internal port `5000` to orchestrate pipeline execution and serve validation reports.

### Available Endpoints
* `GET /`: Serves the main web dashboard interface (`index.html`).
* `POST /start-anonymization`: Triggers the master orchestrator (`run_pipeline.sh`) asynchronously and returns status logs.
* `GET /validation_report.html`: Dynamically serves the latest generated HTML audit report.

### Accessing the Dashboard
1. Spin up the entire containerized stack:
   ```text
   docker compose up -d --build

### Open your browser and navigate to:   

* http://localhost:8080

* Click Start Anonymization to execute the pipeline live, and click View Latest Validation Report to inspect truncation and masking results instantly.

### Managing Exported Anonymized Dumps

When you execute `export.sh`, Oracle Data Pump exports the schema and places the dump file inside a system-generated globally unique identifier (GUID) subdirectory within the container's volume (e.g., `/opt/oracle/exports/<GUID>/domibus_anonymized_sandbox.dmp`). 

The `export.sh` script automatically handles this by:
1. Flattening the directory structure so the dump file is moved directly to the root of your host's `./exports/` folder.
2. Fixing OS-level permissions so the file is fully accessible and ready for extraction or deployment.

You can find your final, clean anonymized dump file locally at:
```text
./exports/domibus_anonymized_sandbox.dmp
```

### Quick Tip: How to Find Your Original Schema Name for `import.sh`

When running `./import.sh`, the script prompts you for the **Original schema name** (`SRC_SCHEMA`) so it can correctly map it to `DOMIBUS_ADMIN` via Oracle's Data Pump `REMAP_SCHEMA` parameter. 

If you forget or aren't sure what schema name was used inside your `.dmp` file, you can quickly inspect the file's contents without importing it by running an Oracle Data Pump index query, or simply check the export log file that came with your dump. 

Typically, for standard Domibus installations or custom exports, this is your production schema name (e.g., `DOMIBUS_ADMIN`, `PRODUCTION_USER`, or your custom database username).

### Contact me

You may contact me if you find any typos, errors, or other issues
https://www.linkedin.com/in/antonis-hapsas-devops/

I will be glad hearing from you :)