FROM python:3.12-alpine

# wireguard-tools: für `wg show`
# bind-tools:      für `dig` (DDNS-Abgleich)
RUN apk add --no-cache wireguard-tools bind-tools

# Python-Abhängigkeiten
RUN pip install --no-cache-dir flask docker

WORKDIR /app
COPY app.py .
COPY static/ static/

EXPOSE 8080
CMD ["python", "app.py"]
