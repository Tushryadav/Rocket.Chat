# Use Node 22.16.0 base image
FROM node:22.16.0-bullseye

# Set working directory
WORKDIR /app

# Install required system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    python3 \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency files FIRST
COPY . .

# Verify Node version
RUN node -v

# Install global tools (ONLY what matters)
RUN npm install -g node-gyp

# Verify installations
RUN corepack enable
RUN yarn --version


# Install dependencies
RUN yarn install

# Copy rest of project
COPY . .

# Expose port (Rocket.Chat default)
EXPOSE 3000

# Start dev server
CMD ["yarn", "dev"]