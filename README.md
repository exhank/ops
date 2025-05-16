# ops

A collection of scripts to automate and simplify the operation and maintenance.

## Usage

### Debian

#### Setup

```bash
cp .env.template .env
# Fill your credentials in `.env` setup section.

# Ensure script is run as root.
chmod +x debian/deploy.sh
debian/deploy.sh
rm .env
```

#### ShadowTLS

```bash
cp .env.template .env
# Fill your credentials in `.env` ShadowTLS section.
# vi .env

# Ensure script is run as root.
chmod +x debian/shadow_tls.sh
debian/shadow_tls.sh
rm .env
```
