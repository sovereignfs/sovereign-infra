# docs/ports.md
# Port registry for this VPS
#
# When adding a new app, pick the next available port from this list and
# add a row. This is the only place port assignments are tracked.
# The actual port lives in apps/<name>/.env (APP_PORT=XXXX).

| Port | App                     | Notes                                     |
|------|-------------------------|-------------------------------------------|
| 4000 | sovereign (runtime)     | Proxied via YOUR_RUNTIME_DOMAIN           |
| 4001 | sovereign (auth)        | Proxied via YOUR_AUTH_DOMAIN              |
| 4002 | — reserved —            |                                           |
| 5000 | (next app goes here)    |                                           |
