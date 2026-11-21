# Golden REST service

The service verifies and applies its embedded SQLite migration before creating
the constructor-injected repository, service and controller. It opens
`users.db` in its working directory and listens on `127.0.0.1:8080` by default.
Pass a different port as the first argument.

- `POST /api/users` accepts `{"displayName":"Ada"}`, validates the name, and
  returns the created row with HTTP 201.
- `GET /api/users/1` returns the stored row with HTTP 200 or an HTTP 404 error.

From the monorepo root, verify the generated migration table and sidecar before
building. Use the pinned REST and SQLite native libraries.

```sh
python3 tools/migration_manifest.py \
  --input examples/golden-rest-service/resources/migrations \
  --output examples/golden-rest-service/generated/golden/migrations.d \
  --module golden.migrations --check
dub build --root=examples/golden-rest-service --compiler=ldc2
python3 examples/golden-rest-service/verify.py examples/golden-rest-service/golden-rest-service
```

The verifier uses a disposable database. It exercises malformed requests,
insertion, fetching, restart, and refusal to start after changing the saved
migration hash. The existing TOML file illustrates the equivalent configuration
values. The executable supplies its settings explicitly.
