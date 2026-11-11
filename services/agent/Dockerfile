# Node 22.18+ runs TypeScript directly (type stripping), so there is no build step.
FROM public.ecr.aws/docker/library/node:22-slim
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --no-audit --no-fund
COPY src ./src
ENV NODE_ENV=production PORT=8000
EXPOSE 8000
CMD ["node", "--import", "./src/instrument.ts", "src/server.ts"]
