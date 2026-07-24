# OCI transports

`zvmi oci` copies and inspects OCI images without a container daemon:

```console
zvmi oci copy docker://registry.example/team/image:stable oci:./layout:stable
zvmi oci copy --override-os linux --override-arch arm64 oci:./layout:stable docker://registry.example/team/image:arm64
zvmi oci copy --all docker://registry.example/team/image:stable oci:./complete:stable
zvmi oci inspect oci:./layout:stable
zvmi oci list-tags docker://registry.example/team/image
```

`copy` prints the committed root digest. `inspect` and `list-tags` print deterministic JSON. Diagnostics are written to stderr.

## References

Registry references are explicit: `docker://host[:port]/repository:tag` or `docker://host[:port]/repository@sha256:<hex>`. Copy and inspect require a tag or digest; list-tags requires a repository with neither. There is no implicit Docker Hub, `latest`, or unqualified-name search.

Local references are `oci:<path>[:name]` or `oci:<path>@sha256:<hex>`. A source without a selector is accepted only when `index.json` has one unambiguous descriptor. A name is the top-level `org.opencontainers.image.ref.name` annotation. A destination without a name creates an unannotated root descriptor.

Only SHA-256 is supported. User information, query strings, fragments, uppercase registry repository components, malformed digests, and unsafe digest-derived paths are rejected.

## Platform selection

Copy and inspect select the host OCI platform by default. Use `--override-os`, `--override-arch`, and `--override-variant` to select another platform. OCI architecture names such as `amd64` and `arm64` are required. Explicit overrides also validate the config platform of a single-manifest image.

`--all` is mutually exclusive with overrides and preserves the complete recursive index graph. Selected-platform mode publishes the matched leaf manifest as the destination root and does not download unrelated platforms. Nested indexes are bounded and cycle checked. Unknown index children are preserved as verified opaque content in `--all` mode.

OCI manifests/indexes and Docker schema-2 manifests/lists are supported. Docker schema 1 is not.

## Exact content and publication

Manifest and index bytes are hashed and copied exactly; publication never reserializes them. Configs, layers, and metadata are verified against descriptor size and SHA-256 while streaming. Existing destination blobs are reused only after verification.

Local layouts publish `index.json` last under an advisory lock. Existing names and unknown descriptor fields are preserved, while replacing a name changes only that reference. An interruption may leave verified unreferenced blobs, but it does not expose a partial new reference.

Registry destinations check for existing blobs, attempt a cross-repository mount for same-registry copies, upload missing content, and publish manifests dependency-first. The destination tag or digest is committed by the final manifest PUT. A failed operation may leave unreferenced blobs or abandoned upload sessions for registry garbage collection.

## Registry options and authentication

HTTPS with system trust and hostname verification is the default. `--tls-ca <pem>` adds certificates to system trust. There is no certificate-verification bypass. `--plain-http` is intended for development registries; credentials and bearer tokens are rejected over non-loopback HTTP.

Copy has separate `--src-authfile`, `--src-tls-ca`, `--src-plain-http`, `--dest-authfile`, `--dest-tls-ca`, and `--dest-plain-http` options. Inspect and list-tags use `--authfile`, `--tls-ca`, and `--plain-http`. Supplying registry options for a local layout is an error.

Credential lookup order is:

1. Explicit auth file
2. `REGISTRY_AUTH_FILE`
3. `${XDG_RUNTIME_DIR}/containers/auth.json`
4. `${XDG_CONFIG_HOME}/containers/auth.json` (or `$HOME/.config/containers/auth.json`)
5. `$HOME/.docker/config.json`
6. `$HOME/.dockercfg`

The client supports `auths`, per-registry `credHelpers`, global `credsStore`, Basic challenges, and Bearer token challenges. The `auth` field is Base64 encoding, not encryption. Credential helpers receive the registry key on stdin, never as a command argument. Credentials, bearer tokens, challenge values, and signed upload URLs are not included in diagnostics.

Responses use identity encoding. Metadata is bounded to 16 MiB, response headers to 64 KiB, and blob streaming uses a 64 KiB buffer. GET and HEAD requests make at most three attempts for transient connection/status failures, with bounded `Retry-After` handling, and follow at most five redirects. HTTPS downgrade is rejected. Registry authorization is stripped from cross-origin blob and signed HTTPS upload requests; token redirects cannot cross origin.

## JSON output

Inspect output has `schema_version`, `reference`, `media_type`, `digest`, `size`, `kind`, `annotations`, `platform`, `config`, `layers`, and `manifests`. Descriptors include media type, digest, size, annotations, and platform where applicable. Selected-platform inspection returns a manifest; `--all` returns the recursive index graph.

Tag output has `schema_version`, `repository`, and a deduplicated, lexically sorted `tags` array. Pagination is automatic and bounded.

## Current limits

The OCI commands do not support schema 1, non-SHA-256 digests, referrers/signatures, trust policies, insecure HTTPS, proxies, mTLS, resumable cross-process uploads, registry catalogs/deletion, layer conversion, or non-OCI transports. Filesystem unpack/repack behavior belongs to issue #223 rather than these transport commands.
