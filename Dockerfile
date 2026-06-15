# GT7 Race Engineer — self-hostable server image
FROM python:3.12-slim

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY gt7dashboard ./gt7dashboard
COPY tools ./tools

# GT7 telemetry is UDP on the LAN — run the container with --network host
# so it can send the heartbeat to the PS5 and receive the broadcast.
EXPOSE 8000
ENV HOST=0.0.0.0 PORT=8000
CMD ["python", "-m", "app.server"]
