# Production deployment

The production workflow builds the Logto Docker image on GitHub Actions, pushes the exact commit
image to GitHub Container Registry, and deploys it over SSH. PostgreSQL and Logto bind only to the
Docker network or server loopback; an HTTPS reverse proxy should provide the public endpoints.

The deployment server needs Docker, Docker Compose, and a restricted deployment account that can
run Docker and write to the deployment directory. Create `/data/cqai-logto` (or the
configured `DEPLOY_BASE`) and grant that account ownership before the first deployment.

## GitHub production environment

Required secrets:

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_KNOWN_HOSTS`
- `GHCR_USERNAME`
- `GHCR_TOKEN` (a token with `read:packages` access to the private image)

Variables:

- `DEPLOY_ENABLED`: set to `true` after the server and domains are ready
- `DEPLOY_BASE`: optional, defaults to `/data/cqai-logto`
- `PUBLIC_HEALTH_URL`: optional external status URL, such as `https://auth.example.com/status`
- `ADMIN_HEALTH_URL`: optional admin status URL

Keep the real Logto runtime values on the server in `/data/cqai-logto/.env`. Start from
`.env.production.example`, then configure DNS and the reverse proxy for `ENDPOINT` and
`ADMIN_ENDPOINT` before enabling automatic deployment. A newly initialized database starts with
Simplified Chinese as the fixed fallback language for both the admin and default tenants.
