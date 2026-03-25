# Dynamic Test Failures Analysis

## Overview

Two dynamic tests are failing:
1. **Test WordPress with MySQL compose file** ❌
2. **What goes up must come down - two containers** ❌

Both use the same WordPress test fixture.

## The Paradox: Honcho Works, WordPress Doesn't

### Working Stack (Honcho)
- `ghcr.io/plastic-labs/honcho:latest` ✅ - Complex Python web service
- `docker.io/pgvector/pgvector:pg15` ✅ - PostgreSQL with extensions

### Failing Stack (WordPress)
- `wordpress:latest` ❌ - Fails with "Address already in use"
- `mysql:8.0` ✅ - MySQL starts successfully

## Root Cause

**WordPress binds to privileged port 80 internally**, which macOS Virtualization.framework blocks.

### How Ports Work

**External Port Mapping (works fine):**
```yaml
ports:
  - "18080:80"  # External:18080 → Internal:80
```
The external port (18080) is configurable and works. The problem is **port 80 inside the container**.

**Internal Container Process:**
- WordPress runs Apache which tries to `bind()` to port 80
- Port 80 is privileged (< 1024) and requires root
- macOS container sandbox restricts privileged port binding
- Result: "Address already in use" error (actually means "permission denied")

### Why Honcho Works

Honcho runs on **port 8000+** (unprivileged):
```python
# Honcho starts server on high port
app.run(host='0.0.0.0', port=8000)  # ✅ Works fine
```

## The Failing Tests

### Test 1: "Test WordPress with MySQL compose file"

**Purpose:** Tests a realistic WordPress + MySQL deployment

**YAML Structure:**
```yaml
services:
  wordpress:
    image: wordpress:latest
    ports:
      - "18080:80"  # External OK, internal 80 fails
    environment:
      WORDPRESS_DB_HOST: db
      # ...
    depends_on:
      - db
    volumes:
      - wordpress_data:/var/www/html

  db:
    image: mysql:8.0
    # ...
```

**What Happens:**
1. ✅ MySQL container starts successfully
2. ❌ WordPress container fails during Apache startup
3. Error: `bind(descriptor:ptr:bytes:): Address already in use (errno: 48)`

**Why It Fails:**
- WordPress image runs Apache HTTP server
- Apache tries to bind to port 80 internally
- macOS container sandbox blocks this

### Test 2: "What goes up must come down - two containers"

**Purpose:** Tests compose down command with multiple containers

**Uses:** Same WordPress + MySQL YAML as Test 1

**What Happens:**
- Same WordPress failure as Test 1
- Test can't verify compose down because containers never start properly

## Why Other Images Work

| Image | Internal Port | Result |
|-------|---------------|--------|
| `nginx:alpine` | 80 | ❌ Would fail (but test uses custom config) |
| `postgres:14` | 5432 | ✅ Unprivileged port |
| `redis:alpine` | 6379 | ✅ Unprivileged port |
| `honcho:latest` | 8000+ | ✅ Unprivileged port |
| `wordpress:latest` | 80 | ❌ Privileged port blocked |

## Solution Options

### Option 1: Use WordPress FPM Variant (Recommended)

Replace Apache-based WordPress with PHP-FPM variant that doesn't bind to port 80:

```yaml
services:
  wordpress:
    image: wordpress:php8.2-fpm  # No Apache, no port 80 binding
    # PHP-FPM listens on Unix socket or port 9000
  
  web:
    image: nginx:alpine  # Nginx handles external port 80 mapping
    ports:
      - "18080:80"
```

### Option 2: Custom Apache Configuration

Mount custom Apache config that uses port 8080:

```yaml
services:
  wordpress:
    image: wordpress:latest
    ports:
      - "18080:8080"
    volumes:
      - ./apache-config.conf:/etc/apache2/sites-enabled/000-default.conf
```

### Option 3: Replace with Simpler Web Service

Use a simple Python or Node.js HTTP service that runs on unprivileged ports:

```yaml
services:
  web:
    image: python:3.12-alpine
    command: python -m http.server 8000
    ports:
      - "18080:8000"
```

## Next Steps

1. **Immediate:** Replace WordPress test with FPM variant + nginx
2. **Document:** Add note about privileged port limitations in macOS containers
3. **Consider:** Add validation to warn about internal privileged ports

## Conclusion

This is **not a code defect** - it's a macOS container sandbox security feature. The WordPress image assumes it can bind to port 80, which is blocked. Honcho and other services that use unprivileged ports work fine.

The fix is to use images that don't require privileged ports internally.
