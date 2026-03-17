# Mook Server

Self-hosted Mook server runtime built with Phoenix, Ash, Postgres, and Oban.

## Development

Preferred CLI entry points use [Task](https://taskfile.dev/):

```bash
task setup
task start
task test
task precommit
```

The app serves HTTP on [`localhost:4000`](http://localhost:4000) by default.

## MVP Local Account Onboarding

Fresh deployments support one documented bootstrap path for the first local account:

- Endpoint: `POST /api/v1/auth/bootstrap`
- Availability: only while no local account exists on the server
- Request body:

```json
{
  "email": "owner@example.com",
  "password": "supersecret123",
  "password_confirmation": "supersecret123"
}
```

- Response: same JSON session payload shape as `POST /api/v1/auth/login`
- Result: creates the first local account in a confirmed, login-capable state

After the first local account exists, this endpoint returns `409` with code `bootstrap_unavailable`. Additional onboarding or public signup flows are not supported yet for the MVP server path.

## Desktop Session Pattern

Desktop JSON auth endpoints under `/api/v1/auth/*` are implemented through the non-persistent `MookServer.Accounts.Session` Ash resource.

Desktop auth/session flows are modeled as an Ash `Session` resource inside `Accounts`. Controllers keep HTTP rendering concerns, while bootstrap/login/refresh/logout orchestration lives behind the resource code interface.

## Security Expectations

- Use HTTPS in production for both bootstrap and login flows.
- Treat the bootstrap endpoint as an operator setup action for trusted initial deployment.
- Do not rely on manual database edits to create the first usable account.
