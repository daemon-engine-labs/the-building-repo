# arena-auth — the sandbox's spend trust boundary (see server.mjs header + DESIGN.md T1).
# Minimal: node runtime + the dependency-free server. No agent CLIs, no secrets baked in — the real
# token is injected at `docker run` time via env, never into an image layer.
FROM node:22-slim
WORKDIR /app
COPY server.mjs /app/server.mjs
# Document the planes; actual bind addresses/ports come from env at run time.
EXPOSE 8080
USER node
ENTRYPOINT ["node", "/app/server.mjs"]
