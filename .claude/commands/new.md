# New Project

You are scaffolding a new project from scratch, creating a GitHub repo, and preparing it for deployment — all in one flow. The goal is "idea to deployed app" in a single command.

## Context

- GitHub auth: !`gh auth status 2>&1 | head -5`
- GitHub username: !`gh api user --jq .login 2>/dev/null || echo "not authenticated"`
- Node.js: !`node --version 2>/dev/null || echo "not installed"`
- Python: !`python3 --version 2>/dev/null || echo "not installed"`
- Existing projects: !`ls ~/projects/ 2>/dev/null || echo "none"`

---

## Before you start

If GitHub CLI is not authenticated, stop and tell the user:
"GitHub CLI is not authenticated. Run `gh auth login` first."
Then stop.

If `$ARGUMENTS` is provided, parse it for a project type and/or name (e.g., `/new nextjs my-app`). Skip the corresponding prompts below.

---

## Step 1 — Choose project type

Ask the user:

```
What kind of project?

  [1] Next.js web app        — App Router, Tailwind CSS, ready to deploy
  [2] React SPA (Vite)       — React + Vite, static build, fast dev server
  [3] Express API             — TypeScript, health endpoint, JSON API
  [4] FastAPI (Python)        — Python API, auto-docs at /docs
  [5] Discord bot             — Discord.js, slash commands, event handlers
  [6] Telegram bot            — grammy, webhook mode, command handlers
  [7] Custom                  — Describe what you want, I'll build it

Pick a number, or describe your project:
```

If the user picks **7 (Custom)**, ask them to describe their project in natural language. Then generate the entire project from their description — treat it like a blank canvas. Use your best judgment for framework choices, file structure, and dependencies. Follow the same git/GitHub/deploy steps below.

If the user types a freeform description instead of a number, treat it as **Custom**.

---

## Step 2 — Choose project name

Ask for a project name. Suggest a sensible default based on the project type (e.g., `my-nextjs-app`, `my-api`).

Validate the name:
- Lowercase, hyphens allowed, no spaces or special characters
- Must not already exist in `~/projects/`

The project directory will be `~/projects/{name}`.

---

## Step 3 — Scaffold the project

Create the project directory and scaffold all files. Do NOT use `create-next-app`, `npm create vite`, or any other CLI scaffolder — write every file directly so you have full control over the output and can tailor it to this environment.

### Template: Next.js web app

Create `~/projects/{name}/` with:

**`package.json`**:
```json
{
  "name": "{name}",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start -p ${PORT:-3000}",
    "lint": "next lint"
  },
  "dependencies": {
    "next": "^15",
    "react": "^19",
    "react-dom": "^19"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4",
    "tailwindcss": "^4",
    "typescript": "^5",
    "@types/node": "^22",
    "@types/react": "^19",
    "@types/react-dom": "^19"
  }
}
```

**`tsconfig.json`**: Standard Next.js TypeScript config with path aliases (`@/*` mapping to `./src/*`).

**`next.config.ts`**: Minimal config, export default `nextConfig = {}`.

**`postcss.config.mjs`**: Tailwind v4 PostCSS config with `@tailwindcss/postcss` plugin.

**`src/app/globals.css`**: Import Tailwind with `@import "tailwindcss";`.

**`src/app/layout.tsx`**: Root layout with html/body, metadata (title = project name), import globals.css.

**`src/app/page.tsx`**: Simple landing page with centered content showing the project name, a brief description, and a "Get Started" section. Use Tailwind classes. Make it look clean and modern with dark background.

**`.gitignore`**: Node modules, `.next/`, `out/`, env files.

Then install dependencies:
```bash
cd ~/projects/{name} && npm install
```

Verify the build works:
```bash
cd ~/projects/{name} && npm run build
```

---

### Template: React SPA (Vite)

Create `~/projects/{name}/` with:

**`package.json`**:
```json
{
  "name": "{name}",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview --port ${PORT:-3000}"
  },
  "dependencies": {
    "react": "^19",
    "react-dom": "^19"
  },
  "devDependencies": {
    "@types/react": "^19",
    "@types/react-dom": "^19",
    "@vitejs/plugin-react": "^4",
    "typescript": "^5",
    "vite": "^6",
    "tailwindcss": "^4",
    "@tailwindcss/vite": "^4"
  }
}
```

**`vite.config.ts`**: React plugin + Tailwind v4 vite plugin, configure server port from env.

**`tsconfig.json`** and **`tsconfig.app.json`**: Standard Vite React TypeScript configs.

**`index.html`**: Vite entry point HTML linking to `/src/main.tsx`.

**`src/main.tsx`**: React DOM createRoot, render `<App />`.

**`src/App.tsx`**: Simple app component with centered content, project name, and a counter button. Tailwind classes.

**`src/index.css`**: Import Tailwind with `@import "tailwindcss";`.

**`.gitignore`**: Node modules, `dist/`, env files.

Then install dependencies:
```bash
cd ~/projects/{name} && npm install
```

Verify the build works:
```bash
cd ~/projects/{name} && npm run build
```

---

### Template: Express API

Create `~/projects/{name}/` with:

**`package.json`**:
```json
{
  "name": "{name}",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "express": "^5",
    "cors": "^2"
  },
  "devDependencies": {
    "@types/express": "^5",
    "@types/cors": "^2",
    "@types/node": "^22",
    "typescript": "^5",
    "tsx": "^4"
  }
}
```

**`tsconfig.json`**: Target ES2022, module NodeNext, outDir `./dist`, rootDir `./src`, strict mode.

**`src/index.ts`**: Express app with:
- CORS enabled
- JSON body parsing
- `GET /` — returns `{ name: "{name}", status: "running" }`
- `GET /health` — returns `{ status: "ok", timestamp: ISO string }`
- `GET /api/hello` — returns `{ message: "Hello from {name}!" }`
- Listens on `process.env.PORT || 3000`
- Logs startup message

**`.gitignore`**: Node modules, `dist/`, env files.

Then install dependencies:
```bash
cd ~/projects/{name} && npm install
```

Verify the build works:
```bash
cd ~/projects/{name} && npm run build
```

---

### Template: FastAPI (Python)

Create `~/projects/{name}/` with:

**`requirements.txt`**:
```
fastapi>=0.115
uvicorn[standard]>=0.34
```

**`app/main.py`**: FastAPI app with:
- `GET /` — returns `{ "name": "{name}", "status": "running" }`
- `GET /health` — returns `{ "status": "ok", "timestamp": ISO string }`
- `GET /api/hello` — returns `{ "message": "Hello from {name}!" }`

**`app/__init__.py`**: Empty file.

**`run.py`**: Uvicorn entry point, reads `PORT` from env (default 3000), runs `app.main:app`.

**`.gitignore`**: `__pycache__/`, `*.pyc`, `.venv/`, env files.

Then set up the virtual environment and install:
```bash
cd ~/projects/{name} && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

Verify the app loads:
```bash
cd ~/projects/{name} && .venv/bin/python -c "from app.main import app; print('OK')"
```

---

### Template: Discord bot

Create `~/projects/{name}/` with:

**`package.json`**:
```json
{
  "name": "{name}",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "deploy-commands": "tsx src/deploy-commands.ts"
  },
  "dependencies": {
    "discord.js": "^14"
  },
  "devDependencies": {
    "@types/node": "^22",
    "typescript": "^5",
    "tsx": "^4"
  }
}
```

**`tsconfig.json`**: Target ES2022, module NodeNext, outDir `./dist`, rootDir `./src`, strict mode.

**`src/index.ts`**: Discord.js client with:
- Intents: Guilds, GuildMessages
- Ready event handler (logs bot username)
- InteractionCreate handler for slash commands
- Reads `DISCORD_TOKEN` from env
- Graceful shutdown on SIGINT/SIGTERM

**`src/commands/ping.ts`**: A `/ping` slash command that replies with "Pong!" and the bot's latency.

**`src/deploy-commands.ts`**: Script to register slash commands with Discord API. Reads `DISCORD_TOKEN` and `DISCORD_CLIENT_ID` from env.

**`.env.example`**:
```
DISCORD_TOKEN=your-bot-token-here
DISCORD_CLIENT_ID=your-client-id-here
```

**`.gitignore`**: Node modules, `dist/`, `.env`, env files.

Then install dependencies:
```bash
cd ~/projects/{name} && npm install
```

Verify the build works:
```bash
cd ~/projects/{name} && npm run build
```

Tell the user after scaffolding:
```
To use this bot:
  1. Create an app at https://discord.com/developers/applications
  2. Copy the bot token and client ID into .env
  3. Run `npm run deploy-commands` to register slash commands
  4. Run `npm run dev` to start the bot
```

---

### Template: Telegram bot

Create `~/projects/{name}/` with:

**`package.json`**:
```json
{
  "name": "{name}",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "grammy": "^1"
  },
  "devDependencies": {
    "@types/node": "^22",
    "typescript": "^5",
    "tsx": "^4"
  }
}
```

**`tsconfig.json`**: Target ES2022, module NodeNext, outDir `./dist`, rootDir `./src`, strict mode.

**`src/index.ts`**: grammy bot with:
- `/start` command — welcome message
- `/help` command — lists available commands
- Text message handler — echoes back the message (as a starter)
- Reads `TELEGRAM_BOT_TOKEN` from env
- Long polling mode for development (easy to switch to webhook for production)
- Graceful shutdown on SIGINT/SIGTERM

**`.env.example`**:
```
TELEGRAM_BOT_TOKEN=your-bot-token-here
```

**`.gitignore`**: Node modules, `dist/`, `.env`, env files.

Then install dependencies:
```bash
cd ~/projects/{name} && npm install
```

Verify the build works:
```bash
cd ~/projects/{name} && npm run build
```

Tell the user after scaffolding:
```
To use this bot:
  1. Message @BotFather on Telegram to create a bot
  2. Copy the token into .env
  3. Run `npm run dev` to start the bot
```

---

### Template: Custom

For Custom projects, use the user's description to determine:
- Language and framework (default to TypeScript/Node.js if ambiguous)
- File structure
- Dependencies
- Entry point and scripts

Scaffold the entire project following the same patterns as above (package.json with scripts, tsconfig if TypeScript, .gitignore, source files). Make it immediately runnable.

---

## Step 4 — Initialize git

```bash
cd ~/projects/{name} && git init && git add -A && git commit -m "Initial scaffold"
```

---

## Step 5 — Create GitHub repo

```bash
cd ~/projects/{name} && gh repo create {name} --private --source . --push
```

If repo creation fails because the name is taken, ask the user for an alternative name.

---

## Step 6 — Deploy (if available)

Check if the `/deploy` command exists:
```bash
ls ~/.claude/commands/deploy.md 2>/dev/null || ls ~/dev-env/.claude/commands/deploy.md 2>/dev/null || echo "not available"
```

- If `/deploy` is available, tell the user: "Ready to deploy! Run `/deploy` to go live."
- If `/deploy` is NOT available, skip this step and note in the summary that deployment can be set up later.

Do NOT attempt to run deployment infrastructure commands directly — always defer to `/deploy`.

---

## Step 7 — Summary

```
Project created!

  Directory: ~/projects/{name}
  GitHub:    https://github.com/{username}/{name}
  Type:      {template type}

  Quick start:
    cd ~/projects/{name}
    {dev command for the template, e.g., "npm run dev"}

  What do you want to build?
```

The last line is key — after scaffolding, transition to **building mode**. You are now the user's coding partner for this project. Ask what they want to build and start coding.

---

## Error handling

- **npm install fails**: Check Node.js version, try clearing npm cache, show the error
- **pip install fails**: Check Python version, try recreating venv
- **gh repo create fails**: Check auth, check if name is taken, suggest alternative
- **Build fails**: Fix the issue before proceeding — the scaffold must compile cleanly
- **Directory already exists**: Tell the user, ask if they want to pick a different name or use the existing directory

Do NOT blindly retry failed commands. Diagnose and fix, or ask the user.
