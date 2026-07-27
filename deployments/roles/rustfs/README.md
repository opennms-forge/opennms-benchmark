# rustfs

Deployment-under-test role: installs [RustFS](https://github.com/rustfs/rustfs),
an S3-compatible object store, and creates the buckets Mimir needs.

Lives here rather than in the `indigo423.opennms` collection because OpenNMS has
no wire to it — OpenNMS writes to Mimir, and Mimir writes here. Under the
collection's scope rule the object store is a lab choice, so `stub_mimir` takes a
generic S3 endpoint and works against AWS S3, MinIO or RustFS alike.

## Why it exists

Multi-node Mimir cannot use its filesystem backend: each node would write blocks
to its own disk, so ingesters, store-gateways and compactors would never see the
same data. A shared object store is the requirement.

## Buckets are created here on purpose

S3 `PutObject` fails against a bucket that does not exist, and **Mimir does not
create its own**. Without them Mimir starts cleanly and then fails every write —
a much harder failure to read than a missing bucket at deploy time.

That is also why the role installs boto3 into a virtualenv rather than using the
distro package: Ubuntu 24.04 ships botocore 1.34.x, while the pinned
`amazon.aws` requires `botocore >= 1.35.0`, so the distro package would abort
every bucket task on a version check.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `rustfs_version` | `1.0.0-beta.11` | Upstream tag. Every RustFS release is still a pre-release; there is no stable 1.0.0 |
| `rustfs_access_key` | **none** | Required — the role ships no default, so the credential assert has something to catch |
| `rustfs_secret_key` | **none** | Required. Written to `/etc/rustfs/credentials` at `0600`, not into the unit |
| `rustfs_s3_port` | `9000` | S3 API, applied via `RUSTFS_ADDRESS` |
| `rustfs_console_enable` | `false` | RustFS enables an admin console by default; off here so it is not exposed with these credentials |
| `rustfs_data_dir` | `/var/lib/rustfs` | `RUSTFS_VOLUMES` |
| `rustfs_buckets` | `mimir-blocks`, `mimir-ruler`, `mimir-alertmanager` | Created at deploy time |

## Not production

Plain HTTP on a private lab subnet, a single node, no TLS and no bucket
policies. It exists to give Mimir somewhere shared to write.

## Example

```yaml
- name: Manage object storage
  hosts: rustfs
  become: true
  roles:
    - role: rustfs
      vars:
        rustfs_access_key: mimir
        rustfs_secret_key: "{{ vault_rustfs_secret_key }}"
```
