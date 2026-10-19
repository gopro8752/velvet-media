FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json ./
COPY src ./src
COPY LICENSE /usr/share/doc/velvet-spectrum/LICENSE
ENV SPECTRUM_CONFIG=/config/spectrum.json
VOLUME ["/config"]
EXPOSE 8812
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD node -e "fetch('http://127.0.0.1:8812/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "src/server.mjs"]
