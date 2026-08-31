# AnkerCore

AnkerCore is an unofficial iPhone companion for the Anker Soundcore Work recorder. Press the recorder button to start, press it again to stop, and AnkerCore securely fetches the completed recording, transcribes it, classifies it as a meeting, task, or idea, and routes it into Notion.

The processing path is privacy-first and cost-aware:

1. Apple Speech transcribes on the iPhone when iOS supports it.
2. Apple Intelligence classifies and summarizes on the iPhone when available.
3. If local classification is unavailable, only transcript text is sent to Cloudflare's inexpensive classifier.
4. Raw audio is sent to Cloudflare Whisper only when local transcription cannot run.

An optional HTTPS webhook can receive the transcript and final Notion routing metadata. Raw audio and credentials are never included in webhook events.

> [!WARNING]
> AnkerCore uses an observed, undocumented Bluetooth protocol. It is not affiliated with or supported by Anker or Soundcore. Export important recordings with the official app before testing. Never factory-reset or unbind the recorder just to make this app connect.

## What you need

- An Anker Soundcore Work recorder (the implementation targets the observed D3200 protocol)
- An iPhone running iOS 17 or newer
- iOS 26 and downloaded Apple speech assets for on-device transcription
- Apple Intelligence enabled on a supported device for on-device classification
- Xcode 26 or newer and an Apple development team
- A Notion account with permission to create an internal integration
- A Cloudflare account with Workers AI access
- Node.js 20 or newer

Cloudflare includes a daily Workers AI allocation. Review [current Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) before production use.

## Repository layout

```text
AnkerCore/                 iOS application source
AnkerCore.xcodeproj/       Xcode project
worker/index.js            Cloudflare Worker and Notion router
worker/wrangler.jsonc      Worker configuration template
```

## 1. Clone and install the Worker tools

```bash
git clone https://github.com/hwhitfield2/AnkerCore.git
cd AnkerCore
npm install
```

Authenticate Wrangler:

```bash
npx wrangler login
```

## 2. Create the Notion integration

1. Create an internal integration at [Notion integrations](https://www.notion.so/profile/integrations).
2. Give it permission to read, insert, and update content.
3. Copy its secret and store it in your password manager.
4. In Notion, create a blank private page that will own AnkerCore's pages and databases.
5. Open the page menu, choose **Connections**, and connect your integration.
6. Copy the page ID from its URL. It is the 32-character value at the end of the page path, before any query string.

Keep the parent page private if the captured material is private. Notion permissions flow down to the databases AnkerCore creates.

## 3. Configure and deploy Cloudflare

Open `worker/wrangler.jsonc` and replace `REPLACE_WITH_NOTION_PARENT_PAGE_ID`. Also set `TIMEZONE_OFFSET` to your fixed UTC offset, such as `-07:00`.

Deploy the initial Worker:

```bash
npm run deploy
```

Wrangler prints a URL similar to:

```text
https://ankercore-router.your-subdomain.workers.dev
```

Add the three secrets below. Wrangler prompts for each value and does not write them to the repository.

```bash
npx wrangler secret put NOTION_TOKEN --config worker/wrangler.jsonc
npx wrangler secret put UPLOAD_TOKEN --config worker/wrangler.jsonc
npx wrangler secret put SETUP_KEY --config worker/wrangler.jsonc
```

- `NOTION_TOKEN` is the internal integration secret.
- `UPLOAD_TOKEN` should be a newly generated random value of at least 32 characters. Save it: the same value goes into the iPhone app.
- `SETUP_KEY` is a separate temporary random value used only for database provisioning.

Generate strong values with `openssl rand -hex 32`, but keep each result in a password manager and never paste it into source files, issues, or chat logs.

Visit `https://YOUR-WORKER.workers.dev/setup`, enter the temporary setup key, and choose **Create Notion databases**. The setup page creates:

- AnkerCore Inbox
- AnkerCore Hub
- Meetings
- Tasks
- Ideas
- Recent Items

Copy the returned IDs into the matching `INBOX_PAGE_ID`, `MEETINGS_DATABASE_ID`, `TASKS_DATABASE_ID`, `IDEAS_DATABASE_ID`, and `RECENT_DATABASE_ID` fields in `worker/wrangler.jsonc`. Redeploy:

```bash
npm run deploy
npx wrangler secret delete SETUP_KEY --config worker/wrangler.jsonc
```

Deleting `SETUP_KEY` disables the provisioning page. Confirm the deployment without exposing credentials:

```bash
curl https://YOUR-WORKER.workers.dev/health
```

## 4. Build the iPhone app

1. Open `AnkerCore.xcodeproj` in Xcode.
2. Select the **AnkerCore** target, then **Signing & Capabilities**.
3. Choose your development team.
4. Change `com.example.AnkerCore` to a bundle identifier you control.
5. Connect your iPhone, select it as the run destination, and press **Run**.
6. Approve Bluetooth and Speech Recognition access when prompted.

In AnkerCore, open **Settings** and enter:

- **Service URL:** `https://YOUR-WORKER.workers.dev/audio`
- **Private token:** the exact `UPLOAD_TOKEN` saved earlier
- **Optional webhook:** a public HTTPS endpoint, or leave blank

The private token and optional webhook URL are stored using `AfterFirstUnlockThisDeviceOnly` Keychain protection.

## 5. Connect and test

1. Export important recordings using the official Soundcore app.
2. Temporarily disable Bluetooth access for the official app in **Settings → Privacy & Security → Bluetooth** so it does not compete for the recorder connection.
3. Open the Soundcore Work case near the iPhone.
4. In AnkerCore, scan and connect to the Soundcore device.
5. Make a short, non-sensitive test recording with the physical button.
6. Press the button again to stop.
7. Watch **Automatic flow**: AnkerCore fetches the file, transcribes it, routes it, and shows a link to the resulting Notion item.

The first on-device transcription may download an Apple speech asset. If local speech or Apple Intelligence is unavailable, the status card clearly identifies the cloud fallback used.

## Routing behavior

AnkerCore creates one routed item in Meetings, Tasks, or Ideas and labels it as:

- **Work** — employer, client, team, or primary-job duties
- **Personal Life** — home, family, health, errands, or leisure
- **Personal Work** — side business, study, creative work, or personal projects
- **Needs Review** — confidence is below the configured threshold

You can force a route by beginning a note with an explicit cue such as `Task:`, `Meeting:`, `Idea:`, `Work:`, `Personal Life:`, or `Personal Work:`.

## Optional webhook

After Notion routing, AnkerCore sends a `POST` request with `Content-Type: application/json` to the configured webhook. Delivery failure is shown in the app but does not undo the Notion item.

```json
{
  "event": "ankercore.recording.processed",
  "version": 1,
  "file_id": "1788150629",
  "recorded_at": "2026-08-30T20:30:29.000Z",
  "transcript": "Example transcript text",
  "routing": {
    "kind": "task",
    "area": "Work",
    "confidence": 0.91,
    "destination": "https://www.notion.so/...",
    "database": "https://app.notion.com/p/..."
  }
}
```

Webhook URLs must use HTTPS, cannot contain URL-embedded usernames or passwords, and cannot target localhost, private host suffixes, or literal IP addresses. Treat signed webhook URLs as secrets.

## Background behavior

The app declares Bluetooth central background mode and uses state restoration. iOS can wake it for Bluetooth activity after it has been opened and connected. iOS will not relaunch an app that the user force-quits, so leave AnkerCore installed and do not swipe it away if you expect automatic fetching.

## Security and privacy

- Recorder transfers use an ephemeral P-256 session and AES-CTR decryption.
- The app only sends observed, whitelisted metadata and fetch commands; there are no delete, reset, bind, or unbind commands.
- Audio chunks and cryptographic key material are omitted from diagnostic captures.
- The Worker requires a constant-time-compared bearer token before reading uploads.
- Audio uploads are type, size, length, file-ID, and Ogg-signature validated.
- Transcript uploads and on-device model output are size- and schema-validated.
- Prompt instructions treat transcripts as untrusted data and do not follow instructions inside them.
- Outbound webhooks are HTTPS-only, reject local/literal-IP targets, do not follow redirects, and time out.
- Worker responses use generic errors and do not log transcript, audio, tokens, or keys.
- `.gitignore` excludes Wrangler state, environment files, Xcode user data, recordings, and diagnostic captures.

Rotate `UPLOAD_TOKEN` immediately if it is ever exposed. Because the app stores it in Keychain, removing and reinstalling the app may not remove the credential; use **Remove private token** in Settings when decommissioning a device.

## Troubleshooting

### The recorder does not appear

- Force-quit the official Soundcore app or disable its Bluetooth access temporarily.
- Reopen the charging case and scan again.
- Do not factory-reset the recorder as a first troubleshooting step.

### Local transcription falls back to cloud

- Confirm the phone runs iOS 26 or newer.
- Allow Speech Recognition access in iPhone settings.
- Connect to Wi-Fi once so Apple can download the speech asset.

### Local classification falls back to cloud

- Confirm Apple Intelligence is enabled and its model has finished downloading.
- Devices that do not support Apple Intelligence will use transcript-only cloud classification.

### The Worker returns `unauthorized`

- Re-enter the exact `UPLOAD_TOKEN` used with `wrangler secret put`.
- Saving a new Cloudflare secret invalidates the value stored in the app.

### Notion routing fails

- Confirm the integration remains connected to the parent Notion page.
- Check that every database ID in `worker/wrangler.jsonc` matches the setup output.
- Inspect Cloudflare invocation logs; do not add transcript or token logging while debugging.

## Development checks

```bash
npm run check
xcodebuild -project AnkerCore.xcodeproj -scheme AnkerCore \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Contributions that change the Bluetooth command surface, authentication, file handling, webhook delivery, or logging should include a focused security review.
