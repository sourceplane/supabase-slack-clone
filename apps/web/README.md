# apps/web — the app

Supabase's [Slack clone example](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)
(its `package.json` says MIT; the supabase/supabase repository it lives in is
Apache-2.0, whose text is `LICENSE` here), running on Cloudflare Workers +
Static Assets:

- Email and password sign-up and sign-in on the home page (`pages/index.js`),
  the session kept by supabase-js in the browser
- Channels and their messages (`pages/channels/[id].js`), each message with
  its author, arriving live over Supabase Realtime (`lib/Store.js`)
- Members, moderators and admins: `pages/_app.js` reads the `user_role`
  claim the project's access-token hook puts in every session, and shows
  the delete buttons a role may use — row-level security enforces them
- `/api/health`, which answers 200 only when the Supabase project the build
  names answers its key and its Data API knows the chat's tables, and says
  how sign-up behaves there
- Tailwind CSS and Sass

Every Supabase call runs in the browser with the publishable key. The
product's name is `lib/site.ts`. The project's URL and publishable key reach
the browser bundle and the Worker from one place, `wrangler.jsonc`'s vars
(`next.config.ts`); the schema they talk to is `packages/db`.

```bash
pnpm dev          # next dev on http://localhost:3000 (reads .env.local)
pnpm build        # next build + opennextjs-cloudflare build → .open-next/
pnpm preview      # wrangler dev over the built Worker (reads .dev.vars)
```

How it runs locally, how it deploys — per environment, after its Supabase
project and its migrations, on merge to `main` — and how roles and email
confirmation work are the repository's README and `component.yaml` beside
this file.
