import json
import random
import string
import re
import oracledb

DB_USER = "DOMIBUS_ADMIN"
DB_PASS = "DomibusPass123"
DB_DSN = "localhost:1521/FREEPDB1"

def generate_random_string(length):
    # Διορθώθηκε: To random.choices παίρνει k=length, αλλά το "".join() παίρνει το αποτέλεσμα ως positional
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
        
    print("🔄 Σύνδεση με την Oracle...")
    connection = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=DB_DSN)
    cursor = connection.cursor()
    
    try:
        # --- 1. ΕΚΤΕΛΕΣΗ TRUNCATES ---
        print("\n🗑️  Εκκίνηση Καθαρισμού (Truncates/Deletes)...")
        for table in config.get("truncates", []):
            try:
                if "QRTZ" in table:
                    cursor.execute(f"DELETE FROM {table}")
                else:
                    cursor.execute(f"TRUNCATE TABLE {table}")
                print(f"  ↳ ✅ Καθαρίστηκε ο πίνακας: {table}")
            except Exception as e:
                print(f"  ↳ ⚠️  Παράκαμψη {table}: {e}")

        # --- 2. ΕΚΤΕΛΕΣΗ ΠΙΝΑΚΩΝ ---
        for table_name, table_config in config.get("tables", {}).items():
            print(f"\n📦 Επεξεργασία πίνακα: {table_name}")
            
            where_clause = table_config.get("where_clause", "")
            where_sql = f" WHERE {where_clause}" if where_clause else ""
            
            is_row_by_row = any(c["method"] in ["RANDOM_STRING", "CONCAT_ID", "REPLACE_SUBSTRINGS", "MASK_EORI_OR_EMAIL", "RANDOM_STRING_DYNAMIC_LENGTH"] 
                                for c in table_config["columns"].values())
            
            if is_row_by_row:
                try:
                    cursor.execute(f"SELECT rowid FROM {table_name}{where_sql}")
                    rows = cursor.fetchall()
                except Exception as e:
                    print(f"  ⚠️  Αδυναμία ανάγνωσης πίνακα {table_name}: {e}")
                    continue
                
                print(f"  ↳ 🔄 Δυναμικό update σε {len(rows)} γραμμές...")
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
                            set_clauses.append(f"{col_name} = UTL_RAW.CAST_TO_RAW('58585858585858585858')")

                    if set_clauses:
                        cursor.execute(f"UPDATE {table_name} SET {', '.join(set_clauses)} WHERE rowid = '{row_id}'")
            else:
                set_clauses = []
                for col_name, col_config in table_config["columns"].items():
                    if col_config["method"] == "STATIC_VALUE":
                        set_clauses.append(f"{col_name} = '{col_config['value']}'")
                    elif col_config["method"] == "EMPTY_BLOB":
                        set_clauses.append(f"{col_name} = UTL_RAW.CAST_TO_RAW('58585858585858585858')")
                
                if set_clauses:
                    sql = f"UPDATE {table_name} SET {', '.join(set_clauses)}{where_sql}"
                    cursor.execute(sql)
                    print(f"  ↳ 🚀 Bulk Updated {cursor.rowcount} γραμμές.")
                    
        connection.commit()
        print("\n🎉 ΟΛΟΚΛΗΡΩΘΗΚΕ ΤΟ MASTER ANONYMIZATION PIPELINE ΜΕ ΕΠΙΤΥΧΙΑ!")

    except Exception as e:
        print(f"❌ Κρίσιμο Σφάλμα: {e}")
        connection.rollback()
    finally:
        cursor.close()
        connection.close()

if __name__ == "__main__":
    run_anonymization()