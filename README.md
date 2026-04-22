# Hetzner Minecraft

Minimal repo for running **All the Mods 10** on a Hetzner VPS with Docker Compose.

This base currently runs Minecraft only, but the folder structure is already arranged so a future Discord bot can be added without restructuring the repo.

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

## Why This Structure

- the repo root stays small and readable
- runtime data does not pollute code directories
- the bot will have a clear home under `services/discord-bot/` without mixing its code with Minecraft
- we can later add a `compose.bot.yml` or a second service in `compose.yml` without moving existing data

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

## Useful Commands

Start:

```bash
docker compose up -d
```

Stop:

```bash
docker compose stop
```

Restart:

```bash
docker compose restart
```

View logs:

```bash
docker compose logs -f minecraft
```

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
