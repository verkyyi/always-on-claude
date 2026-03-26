# Deploy (mobile-friendly)

Deploy the current project. Keep output concise — confirm actions briefly, skip verbose logs unless asked.

## Steps

1. Detect what kind of project this is:

   ```bash
   ls -1 package.json docker-compose.yml Dockerfile Makefile 2>/dev/null || echo "no known project files"
   ```

2. Confirm the deploy plan with the user in one short sentence: what will be built and deployed.

3. Run the appropriate deploy:

   - **Docker Compose project** (has `docker-compose.yml`):

     ```bash
     docker compose up -d --build
     ```

   - **Node.js project** (has `package.json`):

     ```bash
     npm run build 2>&1 | tail -5
     ```

     Then check for a `start` script and run it, or suggest next steps.

   - **Makefile project**:

     ```bash
     make deploy 2>&1 | tail -10
     ```

   - **Other**: Ask the user what command to run.

4. Verify the deploy succeeded:

   ```bash
   # For docker compose:
   docker compose ps 2>/dev/null || true
   # For node:
   # Check if process is running
   ```

5. Report result in one line: success or failure with the key error.

## Important

- Always confirm before deploying
- Show only the last few lines of build output, not the full log
- If deploy fails, show the error and suggest a fix
