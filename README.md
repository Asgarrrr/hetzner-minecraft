# Hetzner Minecraft

Minimal repo for running **All the Mods 10** on a Hetzner VPS with Docker Compose.

The repository currently runs Minecraft only, with a reserved `services/discord-bot/` directory for a future bot.

## Structure

```text
.
├── compose.yml
├── .env.example
├── scripts/
│   ├── bootstrap-ubuntu.sh
│   └── provision-ubuntu.sh
├── services/
│   ├── minecraft/
│   └── discord-bot/
└── volumes/
    └── minecraft/
```

- `compose.yml`: shared Docker orchestration for the repo
- `scripts/bootstrap-ubuntu.sh`: Ubuntu bootstrap script for Docker + first deploy
- `scripts/provision-ubuntu.sh`: fresh-server provisioner with dedicated user + clone + bootstrap
- `services/minecraft/`: docs and files related to the Minecraft server
- `services/discord-bot/`: reserved location for the future bot
- `volumes/minecraft/`: persistent server data

## Prerequisites

- a Hetzner VPS
- a CurseForge API key

## Bootstrap

On a fresh Ubuntu server, after cloning the repo:

```bash
chmod +x scripts/bootstrap-ubuntu.sh
./scripts/bootstrap-ubuntu.sh
```

The script will:

- install Docker Engine and the Compose plugin if needed
- create `.env` from `.env.example` if missing
- ask for `CF_API_KEY` and `RCON_PASSWORD` if they are not already set
- create `./volumes/minecraft`
- pull the image and start the stack

You can also run it non-interactively:

```bash
CF_API_KEY=your_token RCON_PASSWORD=your_password ./scripts/bootstrap-ubuntu.sh
```

Optional overrides:

```bash
CF_API_KEY=your_token \
RCON_PASSWORD=your_password \
MEMORY=20G \
INIT_MEMORY=4G \
VIEW_DISTANCE=6 \
SIMULATION_DISTANCE=4 \
MOTD="Eternia ATM10" \
./scripts/bootstrap-ubuntu.sh
```

If you also want the script to open Minecraft in UFW, set `OPEN_UFW=1`.

## Fresh Server Provisioning

If you want the server to:

- create a dedicated system user
- clone or update the repo
- run the bootstrap automatically

use `scripts/provision-ubuntu.sh`.

With a public repo, the shortest path on a fresh server is:

```bash
curl -fsSL https://raw.githubusercontent.com/Asgarrrr/hetzner-minecraft/main/scripts/provision-ubuntu.sh -o provision-ubuntu.sh
sudo env CF_API_KEY=your_token \
RCON_PASSWORD=your_password \
APP_USER=minecraft \
APP_HOME=/opt/hetzner-minecraft \
bash provision-ubuntu.sh
```

The default `REPO_URL` already points to `https://github.com/Asgarrrr/hetzner-minecraft.git`, so you only need to override it if you fork or rename the repository.

If you ever switch back to a private repo, use either:

```bash
sudo REPO_URL=git@github.com:Asgarrrr/hetzner-minecraft.git bash provision-ubuntu.sh
```

or:

```bash
sudo GITHUB_TOKEN=your_token bash provision-ubuntu.sh
```

Useful options:

- `APP_USER`: dedicated Linux user, default `minecraft`
- `APP_USER_HOME`: Linux home directory for that user, default `/home/minecraft`
- `APP_HOME`: target directory, default `/opt/hetzner-minecraft`
- `REPO_REF`: git branch/tag, default `main`
- `UPDATE_REPO=1`: fetch and fast-forward an existing checkout
- `RUN_BOOTSTRAP=0`: stop after clone/update
- all bootstrap variables such as `CF_API_KEY`, `RCON_PASSWORD`, `MEMORY`, `MOTD`, `OPEN_UFW`

## Manual Installation

1. Copy `.env.example` to `.env`
2. Set `CF_API_KEY` and `RCON_PASSWORD`
3. Start the server:

```bash
docker compose up -d
```

4. Open port `25565/tcp` in the VPS firewall
5. Follow the logs during first boot:

```bash
docker compose logs -f minecraft
```

The first boot can take a while: the container downloads the image, then the ATM10 modpack.

## Configuration

Main variables in `.env`:

- `CF_API_KEY`: required to download the CurseForge modpack
- `RCON_PASSWORD`: RCON password
- `MEMORY`: Java max heap, `16G` by default
- `INIT_MEMORY`: Java initial heap, `4G` by default
- `CF_FILENAME_MATCHER`: ATM10 version to install, `6.6` by default

## Data

All persistent data is stored in `./volumes/minecraft`.

If you want to migrate an existing world later, place the world files in that directory before restarting the container.
