# Playwright's image already has Chromium and its system libraries.
FROM mcr.microsoft.com/playwright:v1.63.0-noble
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund --loglevel=error
COPY traffic.mjs ./
CMD ["node", "traffic.mjs"]
