# Shōsai website

This directory contains the Hugo source for the Shōsai project website. It uses custom templates and CSS only—there is no theme or JavaScript dependency to install.

## Local development

From the repository root:

```sh
hugo server --source website
```

Build the production site with:

```sh
hugo --source website --minify
```

The generated files are written to `website/public/` and are ignored by Git.

## Cloudflare Pages

Create a Pages project connected to this GitHub repository with these settings:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | `Hugo` |
| Build command | `hugo --source website --minify` |
| Build output directory | `website/public` |
| Root directory | *(repository root)* |
| Node.js version | Not required |

Cloudflare Pages provides Hugo when using the Hugo framework preset. Once the custom domain is known, update `baseURL` in `hugo.toml` to its canonical `https://` URL.

### Build watch paths

To avoid deploying the site for application-only changes, go to **Settings** > **Build** > **Build watch paths** in the Pages project and configure:

| Setting | Value |
| --- | --- |
| Include paths | `website/*`, `assets/fonts/*` |
| Exclude paths | *(empty)* |

The website mounts the shared font assets from `assets/fonts`, so changes to either the Hugo source or bundled fonts must trigger a deployment.
