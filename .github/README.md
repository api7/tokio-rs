# Tokio for Apache APISIX

This is API7's maintenance repository for the Tokio changes that Apache APISIX
needs on top of released Tokio versions. Use upstream
[tokio-rs/tokio](https://github.com/tokio-rs/tokio) for anything else.

- `dev` holds the current line: the upstream release named in
  [`apisix/BASE`](../apisix/BASE) and a linear series of reviewed patches.
- Builds use release tags `apisix-<version>-p<N>`, never a branch.
- Changes that suit upstream are proposed to tokio-rs/tokio and dropped here
  once a release contains them.

How the line is maintained, how to contribute and how to use a release:
[`apisix/README.md`](../apisix/README.md).

The upstream Tokio README: [`README.md`](../README.md).
