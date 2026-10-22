FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 wireguard-tools ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY egress.py ./
COPY LICENSE /usr/share/doc/velvet-spectrum-egress/LICENSE
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s CMD ["python", "/app/egress.py", "--health"]
CMD ["python", "/app/egress.py"]
