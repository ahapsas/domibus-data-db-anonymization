FROM python:3.9-slim

WORKDIR /app

# Install system dependencies if needed (e.g., bash, curl)
RUN apt-get update && apt-get install -y --no-install-recommends bash && rm -rf /var/lib/apt/lists/*

# Install python oracle driver
RUN pip install --no-cache-dir oracledb flask

# Copy project files
COPY . /app

# Ensure shell scripts are executable inside the container
RUN chmod +x run_pipeline.sh export.sh import.sh

EXPOSE 5000

CMD ["python3", "app.py"]