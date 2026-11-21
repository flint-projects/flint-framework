# Golden REST service

The source declares a persisted User DTO, generated repository binding, constructor-injected UserService and annotated controller, then starts a loopback server. The sample's explicit SQLite settings are in source; the TOML file illustrates matching application configuration for the later configuration-injection exercise. No claim is made that this file is loaded by the current source.

`GET /api/users/1` returns a user or the specified 404 error mapping. `POST /api/users` validates the request and saves it with prepared parameters. Text fields are request-arena handles, so parsing, persistence and response serialization share a precisely bounded lifetime. The startup schema is solely a standalone demonstration; production composition invokes flint:migrate before admitting traffic.

The supplied sample is compiler-checked against contracts. It becomes runnable after Milestone 3 implements the dependencies. It is intentionally distinct from bench-rest, which has no database and is matched against the minimal Go reference. Do not benchmark this database application against a Go server that merely returns static JSON.
