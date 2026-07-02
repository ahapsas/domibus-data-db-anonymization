import json
import oracledb
from datetime import datetime

# Database Connection Details
PROD_DSN = "localhost:1521/FREEPDB1"
ANON_DSN = "localhost:1522/FREEPDB1"
DB_USER = "DOMIBUS_ADMIN"
DB_PASS = "DomibusPass123"

def generate_html_report():
    print(" Starting Data Validation Report...")
    
    with open("mapping.json", "r", encoding="utf-8") as f:
        config = json.load(f)

    # Connect to both databases
    try:
        prod_conn = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=PROD_DSN)
        anon_conn = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=ANON_DSN)
        prod_cursor = prod_conn.cursor()
        anon_cursor = anon_conn.cursor()
        print(" Successfully connected to both Production and Sandbox databases.")
    except Exception as e:
        print(f" Connection failed: {e}")
        return

    # --- VERIFY TRUNCATIONS ---
    print("\n🔍 Verifying Truncated Tables...")
    truncation_results = []
    for table in config.get("truncates", []):
        try:
            anon_cursor.execute(f"SELECT count(*) FROM {table}")
            count = anon_cursor.fetchone()[0]
            status = " Empty" if count == 0 else f" {count} rows found!"
            truncation_results.append((table, status))
            print(f"  {status.split(' ')[0]} {table}: {status}")
        except Exception as e:
            print(f"   Could not verify {table}: {e}")

    # Start HTML Template
    html = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <title>Domibus Anonymization Report</title>
        <style>
            body {{ font-family: sans-serif; background-color: #f4f7f6; color: #333; margin: 40px; }}
            h1 {{ color: #2c3e50; border-bottom: 2px solid #3498db; }}
            h2 {{ color: #2980b9; margin-top: 30px; }}
            table {{ width: 100%; border-collapse: collapse; margin-top: 15px; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
            th, td {{ padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }}
            th {{ background-color: #34495e; color: white; }}
            .status-ok {{ color: green; font-weight: bold; }}
            .binary-info {{ color: #7f8c8d; font-style: italic; }}
            .timestamp {{ color: #7f8c8d; }}
        </style>
    </head>
    <body>
        <h1> Domibus Anonymization Audit</h1>
        <h2> Antonios Chapsas Devops - 2026</h2>
        <div class="timestamp">Generated on: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</div>
        
        <h2>Table Truncation Status</h2>
        <ul>
            {"".join([f"<li><code>{t}</code>: <span class='status-ok'>{s}</span></li>" for t, s in truncation_results])}
        </ul>
    """

    # Process each table
    for table_name, table_config in config.get("tables", {}).items():
        columns = list(table_config["columns"].keys())
        col_str = ", ".join(columns)
        
        try:
            prod_cursor.execute(f"SELECT ID_PK, {col_str} FROM {table_name} WHERE rownum <= 3")
            prod_rows = prod_cursor.fetchall()
            
            if prod_rows:
                # Check if we can represent the first row as string (detect BLOBs)
                first_val = str(prod_rows[0][1])
                
                html += f"<h2>Data Masking Check: <code>{table_name}</code></h2>"
                
                if "bytes" in first_val or "LOB" in first_val:
                    html += "<p class='binary-info'>Note: Table contains binary/LOB data - Preview skipped.</p>"
                else:
                    html += "<table><thead><tr><th>Column</th><th>Original</th><th>Anonymized</th></tr></thead><tbody>"
                    for prod_row in prod_rows:
                        id_pk = prod_row[0]
                        prod_vals = prod_row[1:]
                        anon_cursor.execute(f"SELECT {col_str} FROM {table_name} WHERE ID_PK = :1", [id_pk])
                        anon_row = anon_cursor.fetchone()
                        if anon_row:
                            for i, col_name in enumerate(columns):
                                html += f"<tr><td>{col_name}</td><td>{prod_vals[i]}</td><td>{anon_row[i]}</td></tr>"
                    html += "</tbody></table>"
            print(f"  ↳ Processed: {table_name}")
        except Exception as e:
            print(f"  ↳ Skipping {table_name}: {e}")

    html += "</body></html>"

    with open("validation_report.html", "w", encoding="utf-8") as f:
        f.write(html)
        
    print("\n SUCCESS: validation_report.html generated!")
    prod_cursor.close()
    prod_conn.close()
    anon_cursor.close()
    anon_conn.close()

if __name__ == "__main__":
    generate_html_report()