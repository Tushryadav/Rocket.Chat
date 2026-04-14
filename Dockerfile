# Use Node 22.16.0 base image
FROM node:22.16.0-bullseye AS builder

# Set working directory
WORKDIR /app

# Install required system dependencies
RUN apt-get update && apt-get install -y \
     curl \
     build-essential \
     python3 \
     git \
     && rm -rf /var/lib/apt/lists/*

RUN npm install -g deno
# Install global tools (ONLY what matters)
RUN npm install -g node-gyp

RUN corepack enable
RUN corepack prepare yarn@4.12.0 --activate


# Copy rest of source (controlled by .dockerignore)
COPY . .

# Install dependencies
RUN yarn install


# Build app
RUN yarn build

# ---------- Stage 2: Runtime ----------
FROM node:22-alpine

WORKDIR /app

# Copy only built output
COPY --from=builder /app /app

# Expose port (Rocket.Chat default)
EXPOSE 3000

# Start dev server
CMD ["node", "main.js"]
