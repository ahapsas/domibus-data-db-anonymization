# This script is designed to anonymize sensitive data in an Oracle Domibus database 
# based on the configuration provided in the mapping.json file. 
# It connects to the database, performs truncation or deletion of specified tables,
# deleting or anonymizing sensitive data in other tables, and updates specific columns 
# with anonymized values according to the defined methods. 

# If you want to run this script alone, execute it by: python anonymizer.py

import json
import random
import string
import re
import oracledb

DB_USER = "DOMIBUS_ADMIN"
DB_PASS = "DomibusPass123"
DB_DSN = "localhost:1522/FREEPDB1"  # Port 1522 connects straight to your Sandbox Container

def generate_random_string(length):
    choices_list = random.choices(string.ascii_uppercase + string.digits, k=length)
    return ''.join(choices_list)

def mask_eori_text(text):
    if not text: return text
    eori_pattern = r'[A-Z]{2}[0-9]{8,}'
    
    def repl(match):
        letters_list = random.choices(string.ascii_uppercase, k=2)
        letters = ''.join(letters_list)
        
        numbers_list = random.choices(string.digits, k=len(match.group()) - 2)
        numbers = ''.join(numbers_list)
        
        return letters + numbers
        
    return re.sub(eori_pattern, repl, text)

def run_anonymization():
    with open("mapping.json", "r", encoding="utf-8") as f:
        config = json.load(f)
        
    print("Connecting to Sandbox Database Context...")
    connection = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=DB_DSN)
    cursor = connection.cursor()
    
    try:
        # --- 1. EXECUTE CLEANUP PROCESS (TRUNCATES / DELETES) ---
        print("\n Starting Cleanup Process (Truncates/Deletes)...")
        for table in config.get("truncates", []):
            try:
                if "QRTZ" in table:
                    cursor.execute(f"DELETE FROM {table}")
                else:
                    cursor.execute(f"TRUNCATE TABLE {table}")
                print(f"  ↳ Cleared table: {table}")
            except Exception as e:
                print(f"  ↳ Skipping {table}: {e}")

        # --- 2. EXECUTE TABLE PROCESSING ENGINE ---
        for table_name, table_config in config.get("tables", {}).items():
            print(f"\n Processing table: {table_name}")
            
            where_clause = table_config.get("where_clause", "")
            where_sql = f" WHERE {where_clause}" if where_clause else ""
            
            is_row_by_row = any(c["method"] in ["RANDOM_STRING", "CONCAT_ID", "REPLACE_SUBSTRINGS", "MASK_EORI_OR_EMAIL", "RANDOM_STRING_DYNAMIC_LENGTH"] 
                                for c in table_config["columns"].values())
            
            if is_row_by_row:
                try:
                    cursor.execute(f"SELECT rowid FROM {table_name}{where_sql}")
                    rows = cursor.fetchall()
                except Exception as e:
                    print(f"  Unable to read table {table_name}: {e}")
                    continue
                
                print(f"  ↳ Dynamic update on {len(rows)} rows...")
                for row in rows:
                    row_id = row[0]
                    set_clauses = []
                    
                    for col_name, col_config in table_config["columns"].items():
                        method = col_config["method"]
                        
                        if method == "RANDOM_STRING":
                            set_clauses.append(f"{col_name} = '{generate_random_string(col_config['length'])}'")
                        
                        elif method == "CONCAT_ID":
                            cursor.execute(f"SELECT ID_PK FROM {table_name} WHERE rowid = '{row_id}'")
                            id_pk = cursor.fetchone()[0]
                            final_val = f"{col_config.get('prefix','')}{id_pk}{col_config.get('suffix','')}"
                            set_clauses.append(f"{col_name} = '{final_val}'")
                            
                        elif method == "MASK_EORI_OR_EMAIL":
                            cursor.execute(f"SELECT {col_name} FROM {table_name} WHERE rowid = '{row_id}'")
                            orig_val = cursor.fetchone()[0]
                            if orig_val:
                                if "@" in str(orig_val):
                                    parts = str(orig_val).split("@")
                                    masked_val = generate_random_string(8) + "@" + parts[1]
                                else:
                                    masked_val = mask_eori_text(str(orig_val))
                                set_clauses.append(f"{col_name} = '{masked_val}'")
                                
                        elif method == "RANDOM_STRING_DYNAMIC_LENGTH":
                            cursor.execute(f"SELECT {col_name} FROM {table_name} WHERE rowid = '{row_id}'")
                            orig_val = cursor.fetchone()[0]
                            length = len(str(orig_val)) if orig_val else 5
                            set_clauses.append(f"{col_name} = '{generate_random_string(length)}'")
                            
                        elif method == "STATIC_VALUE":
                            set_clauses.append(f"{col_name} = '{col_config['value']}'")
                            
                        elif method == "EMPTY_BLOB":
                            set_clauses.append(f"{col_name} = UTL_RAW.CAST_TO_RAW('ANONYMOUS')")

                    if set_clauses:
                        cursor.execute(f"UPDATE {table_name} SET {', '.join(set_clauses)} WHERE rowid = '{row_id}'")
            else:
                set_clauses = []
                for col_name, col_config in table_config["columns"].items():
                    if col_config["method"] == "STATIC_VALUE":
                        set_clauses.append(f"{col_name} = '{col_config['value']}'")
                    elif col_config["method"] == "EMPTY_BLOB":
                        set_clauses.append(f"{col_name} = UTL_RAW.CAST_TO_RAW('ANONYMOUS')")
                
                if set_clauses:
                    sql = f"UPDATE {table_name} SET {', '.join(set_clauses)}{where_sql}"
                    cursor.execute(sql)
                    print(f"  ↳ Bulk Updated {cursor.rowcount} rows.")
                    
        connection.commit()
        print("\n THE ANONYMIZATION PROCESS COMPLETED SUCCESSFULLY!")

    except Exception as e:
        print(f" Critical Error: {e}")
        connection.rollback()
    finally:
        cursor.close()
        connection.close()
        print(" Database session disconnected safely.")

if __name__ == "__main__":
    run_anonymization()