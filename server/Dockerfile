FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY . .

# Create volume mount points
RUN mkdir -p /games /data

EXPOSE 11451

ENV SENA_GAMES_PATH=/games
ENV SENA_DATA_PATH=/data

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "11451"]
