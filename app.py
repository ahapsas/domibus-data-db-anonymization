import subprocess
from flask import Flask, jsonify, send_from_directory
import os

app = Flask(__name__)

@app.route('/start-anonymization', methods=['POST'])
def start_anonymization():
    try:
        print("-> Triggering pipeline execution...")
        # Run the shell script and capture both stdout and stderr
        # Using 'bash' explicitly to avoid any executable permission issues
        result = subprocess.run(
            ['bash', './run_pipeline.sh'], 
            capture_output=True, 
            text=True, 
            check=True
        )
        print("-> Pipeline completed successfully.")
        return jsonify({"status": "success", "output": result.stdout}), 200
    except subprocess.CalledProcessError as e:
        error_msg = f"Command failed with exit code {e.returncode}.\nSTDOUT: {e.stdout}\nSTDERR: {e.stderr}"
        print(f"❌ Error: {error_msg}")
        return jsonify({"status": "error", "message": error_msg}), 500
    except Exception as ex:
        print(f"❌ Unexpected Error: {str(ex)}")
        return jsonify({"status": "error", "message": str(ex)}), 500

@app.route('/validation_report.html', methods=['GET'])
def get_report():
    report_path = 'validation_report.html'
    
    # If the report doesn't exist, try generating it automatically on-the-fly
    if not os.path.exists(report_path):
        print("-> Validation report not found. Generating on the fly...")
        try:
            # Fixed the stray comma syntax error here
            subprocess.run(['python3', 'validator.py'], check=True)
        except Exception as e:
            return f"Validation report not found and failed to generate automatically: {str(e)}", 500

    if os.path.exists(report_path):
        return send_from_directory('.', report_path)
    else:
        return "Validation report could not be generated.", 404

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)