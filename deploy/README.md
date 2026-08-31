# Production deployment

The production workflow builds the Logto Docker image on GitHub Actions, pushes the exact commit
image to GitHub Container Registry, and deploys it over SSH. PostgreSQL and Logto bind only to the
Docker network or server loopback; an HTTPS reverse proxy should provide the public endpoints.

The deployment server needs Docker, Docker Compose, and a restricted deployment account that can
run Docker and write to the deployment directory. Create `/data/cqai-logto` (or the
configured `DEPLOY_BASE`) and grant that account ownership before the first deployment.

The workflow mirrors PostgreSQL 17 Alpine to the repository's GHCR package under the
`postgres-17-alpine` tag. Production pulls both application and database images from GHCR because
the `shujubang` host cannot reliably reach Docker Hub.

The current production target is the shared `shujubang` host. Ports `3001` and `3002` are already
used there, so this deployment binds Logto to `127.0.0.1:3011` and the Admin Console to
`127.0.0.1:3012`. The production Nginx configuration is tracked in
`deploy/nginx.cqai-logto.conf`.

The `Renew production certificate` workflow requests a certificate for `auth.cqaiclub.asia` and
`auth-admin.cqaiclub.asia` on the first day of every month. It uses an HTTP challenge uploaded over
the restricted production SSH connection, then validates and reloads Nginx after installing the
renewed certificate.

## GitHub production environment

Required secrets:

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_KNOWN_HOSTS`

The workflow uses its short-lived `GITHUB_TOKEN` to let the server pull the private image during
deployment, so no long-lived GitHub package token is required.

Variables:

- `DEPLOY_ENABLED`: set to `true` after the server and domains are ready
- `DEPLOY_BASE`: optional, defaults to `/data/cqai-logto`
- `PUBLIC_HEALTH_URL`: optional external status URL, such as `https://auth.example.com/status`
- `ADMIN_HEALTH_URL`: optional admin status URL

Keep the real Logto runtime values on the server in `/data/cqai-logto/.env`. Start from
`.env.production.example`, then configure DNS and the reverse proxy for `ENDPOINT` and
`ADMIN_ENDPOINT` before enabling automatic deployment. A newly initialized database starts with
Simplified Chinese as the fixed fallback language for both the admin and default tenants.
