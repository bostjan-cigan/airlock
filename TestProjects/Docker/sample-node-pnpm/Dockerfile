FROM node:20-alpine
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod
COPY src ./src
COPY scripts ./scripts
COPY test ./test
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
