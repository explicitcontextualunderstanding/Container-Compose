# Dynamic Test Failures Analysis

## Overview

Two dynamic tests are currently experiencing runtime issues:

1. **Test WordPress with MySQL compose file** ❌ - Container exit code 1
2. **What goes up must come down - two containers** ❌ - Same WordPress setup issue

**Status:** The original privileged port issue has been **resolved**. Current failures are due to **multi-container orchestration complexity**.

---

## Issue Evolution

### Phase 1: Privileged Port Problem (RESOLVED ✅)

**Original Issue:** `wordpress:latest` (Apache) binds to port 80 internally, which macOS Virtualization.framework blocks.

**Root Cause:**
- macOS container sandbox restricts privileged ports (< 1024)
- WordPress Apache tried `bind()` to port 80
- Error 48 (EADDRINUSE) was actually "permission denied" in disguise

**Fix Applied:**
```yaml
# BEFORE (Failed)
wordpress:
  image: wordpress:latest  # Apache on port 80

# AFTER (Should work)
wordpress:
  image: wordpress:php8.2-fpm  # PHP-FPM on port 9000 (unprivileged)
  
web:
  image: nginx:alpine
  ports:
    - "18080:8080"  # External:Internal - both unprivileged
```

---

## Phase 2: Multi-Container Orchestration Complexity (CURRENT)

### Current Architecture

```yaml
services:
  wordpress:
    image: wordpress:php8.2-fpm  # PHP-FPM listens on port 9000
    environment:
      WORDPRESS_DB_HOST: db
    volumes:
      - wordpress_data:/var/www/html

  web:
    image: nginx:alpine
    ports:
      - "18080:8080"  # Both unprivileged ✅
    volumes:
      - wordpress_data:/var/www/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro  # Custom config
    depends_on:
      - wordpress

  db:
    image: mysql:8.0  # Port 3306 (unprivileged) ✅
```

### Current Failure Mode

**Error:** Container run failed with exit code 1

**Not the same error as before!**

| Aspect | Before (Privileged Port) | Now (Runtime Config) |
|--------|--------------------------|----------------------|
| **Error** | `bind(): Address already in use (errno: 48)` | Container run failed with exit code 1 |
| **Phase** | Container bootstrap | Container startup/runtime |
| **Cause** | Privileged port 80 blocked | Likely nginx/PHP-FPM communication |
| **Status** | Fixed ✅ | Under investigation |

### Potential Issues

1. **nginx Configuration**
   - Config file mounting: `./nginx.conf:/etc/nginx/conf.d/default.conf:ro`
   - Is the mount working? File paths correct?
   - fastcgi_pass to `wordpress:9000` working?

2. **Container Networking**
   - Service name resolution: `wordpress` → IP
   - Can nginx reach PHP-FPM on port 9000?

3. **PHP-FPM Startup**
   - Is PHP-FPM actually listening on port 9000?
   - WordPress initialization (database connection)?

4. **Volume Mounts**
   - Shared volume `wordpress_data` accessible by both containers?

### Why Honcho Works But WordPress FPM Doesn't

| Stack | Honcho | WordPress FPM |
|-------|--------|---------------|
| **Containers** | 1 | 3 |
| **Internal Communication** | None (self-contained) | nginx ↔ PHP-FPM (fastcgi) |
| **Config Complexity** | Simple | Multi-service orchestration |
| **Service Discovery** | N/A | Required (container names → IPs) |
| **macOS Status** | ✅ Works | ⚠️ Needs debugging |

---

## Why This Matters

WordPress is **the most popular multi-tier application** in the world:
- 40%+ of all websites use WordPress
- Standard architecture: PHP-FPM + nginx/Apache + MySQL
- If container-compose can't run WordPress, it's not ready for production

This is **exactly the complexity real users face**:
- Multi-container orchestration
- Service discovery
- Volume sharing
- Internal networking
- Configuration management

---

## Next Steps

### Option 1: Debug Current Setup (Recommended)

Investigate the runtime failure:
1. Check container logs: `container logs <container-id>`
2. Verify nginx config mount: `container exec <nginx-id> cat /etc/nginx/conf.d/default.conf`
3. Verify PHP-FPM listening: `container exec <wordpress-id> netstat -tlnp`
4. Test networking: Can nginx reach `wordpress:9000`?

### Option 2: Simplify Test (Short-term)

Use a simpler web stack that still validates multi-container orchestration:
```yaml
services:
  web:
    image: nginx:alpine
    ports:
      - "18080:8080"
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
    depends_on:
      - api
  
  api:
    image: node:18-alpine
    command: node -e "require('http').createServer((req,res)=>res.end('OK')).listen(3000)"
```

### Option 3: Investigate WordPress Image

Check if there's a simpler WordPress variant:
- `wordpress:cli` - Command-line only
- Custom WordPress image with pre-configured non-privileged ports

---

## Conclusion

**The privileged port issue is FIXED.** The current problem is **multi-container orchestration complexity** - which is exactly what container-compose is supposed to solve.

### 4. Discovery: Service Name Length Constraint (The "wp" Fix)

**Symptom:** Even after switching to Alpine images, the `wordpress` service continued to fail with `NSPOSIXErrorDomain Code=22 ("Invalid argument")` during `vmexec`, while the `db` service (MySQL) started consistently.

**Root Cause:** The macOS `Virtualization.framework` (and specifically the `VZLinuxBootLoader` guest label buffer) appears to have a strict character limit for container labels/hostnames. 

- **Failing Name:** `Container-Compose_Tests_UUID-wordpress` (~70 characters)
- **Passing Name:** `Container-Compose_Tests_UUID-wp` (~63 characters)

By shortening the service name from `wordpress` to `wp`, the total ID fell within the 64-character limit typical of BSD/Darwin `MAXHOSTNAMELEN` buffers, resolving the "Invalid argument" error immediately.

**Recommendation:** For development environments using long project prefixes or UUIDs, keep service names as short as possible (e.g., `wp` instead of `wordpress`, `db` instead of `database`).

**Safety Feature:** A proactive validation check has been added to `ComposeUp.swift` to warn users if their generated container names exceed 63 characters.
