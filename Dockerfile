# Use official Rocket.Chat image (DO NOT rebuild app)
FROM rocketchat/rocket.chat:6.8.0

# Switch to root to make controlled changes
USER root

# Install minimal required tools (no bloat)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Drop privileges
USER rocketchat

# Healthcheck (helps orchestration & monitoring)
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
 CMD node -e "require('http').get('http://localhost:3000/api/v1/info', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

