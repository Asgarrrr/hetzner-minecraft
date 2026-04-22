# Hetzner Minecraft

Minimal repo for running **All the Mods 10** on a Hetzner VPS with Docker Compose.

The repository currently runs Minecraft only, with a reserved `services/discord-bot/` directory for a future bot.

## Structure

```text
.
├── compose.yml
├── .env.example
├── services/
│   ├── minecraft/
│   └── discord-bot/
└── volumes/
    └── minecraft/
```

- `compose.yml`: shared Docker orchestration for the repo
- `services/minecraft/`: docs and files related to the Minecraft server
- `services/discord-bot/`: reserved location for the future bot
- `volumes/minecraft/`: persistent server data

## Prerequisites

- a Hetzner VPS
- Docker Engine + Docker Compose plugin installed
- a CurseForge API key

## Installation

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
