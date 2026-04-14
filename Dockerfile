# Use official Rocket.Chat image (DO NOT rebuild app)
FROM rocketchat/rocket.chat:6.8.0

# Switch to root to make controlled changes
USER root

# Install minimal required tools (no bloat)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user (security best practice)
RUN useradd -m -s /bin/bash appuser

# Set ownership (important if writing files/logs)
COPY --chown=appuser:appuser . /app

# Drop privileges
USER appuser

WORKDIR /app

# Expose application port
EXPOSE 3000

# Healthcheck (helps orchestration & monitoring)
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
 CMD node -e "require('http').get('http://localhost:3000/api/v1/info', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

# Default command (keep original behavior)
CMD ["node", "main.js"]
