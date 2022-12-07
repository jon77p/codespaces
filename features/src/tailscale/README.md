
# Tailscale (tailscale)

Installs Tailscale and configures it to connect to your Tailscale network. Note: You need to create a [Reusable Authkey](https://login.tailscale.com/admin/settings/authkeys) for your Tailnet and add it as a [Codespaces Secret](https://github.com/settings/codespaces) named `TAILSCALE_AUTHKEY`.

## Example Usage

```json
"features": {
    "ghcr.io/jon77p/codespaces/features/tailscale:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Tailscale version | string | latest |
| tailscale_hostname | Tailscale hostname | string | codespaces |



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/jon77p/codespaces/blob/main/features/src/tailscale/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
