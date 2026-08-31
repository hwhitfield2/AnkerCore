# AnkerCore

AnkerCore is an unofficial iPhone companion for the Anker Soundcore Work recorder. Press the recorder button to start, press it again to stop, and AnkerCore securely fetches the completed recording, transcribes it, extracts every meeting, task, and idea, and routes linked records into Notion. The app also shows your live open-task list and can mark tasks complete.

The processing path is privacy-first and cost-aware:

1. Apple Speech transcribes on the iPhone when iOS supports it.
2. Apple Intelligence classifies and summarizes on the iPhone when available.
3. If local classification is unavailable, only transcript text is sent to Cloudflare's inexpensive classifier.
4. Raw audio is sent to Cloudflare Whisper only when local transcription cannot run.
5. Optional speaker diarization and enrolled voice identification run on the iPhone.

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
- Internet access on first voice enrollment so the open-source diarization models can download

Cloudflare includes a daily Workers AI allocation. Review [current Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) before production use.

## Repository layout

```text
AnkerCore/                 iOS application source
AnkerCore.xcodeproj/       Xcode project
AnkerCoreWidget/           Home-screen status and task widget
Shared/                    App/widget snapshot models
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

Visit `https://YOUR-WORKER.workers.dev/setup`, enter the temporary setup key, and choose **Create a new Notion workspace**. The setup page creates:

- AnkerCore Inbox
- AnkerCore Hub
- Meetings
- Tasks
- Ideas
- Recent Items
- People
- Projects
- Clients
- Processing Log
- Daily Digests
- Routing Feedback

Copy each returned database/page ID into its matching field in `worker/wrangler.jsonc`. The reconciliation counters are informational and do not belong in the configuration. Existing installations can deploy the new Worker temporarily with `SETUP_KEY`, visit `/setup`, and choose **Upgrade existing AnkerCore databases**; rows are retained while the new databases, properties, and relations are added.

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
4. The public target uses `com.ankercore.app`. Change it to a bundle identifier your team owns if you are creating a separate App Store record.
5. Register an App Group for the app and widget. The included targets use `group.com.ankercore.app`; forks should change that value in both entitlements files and `Shared/WidgetData.swift`.
6. Connect your iPhone, select it as the run destination, and press **Run**.
7. Approve Bluetooth and Speech Recognition access when prompted.

In AnkerCore, open **Settings** and enter:

- **Service URL:** `https://YOUR-WORKER.workers.dev/audio`
- **Private token:** the exact `UPLOAD_TOKEN` saved earlier
- **Optional webhook:** a public HTTPS endpoint, or leave blank

The private token and optional webhook URL are stored using `AfterFirstUnlockThisDeviceOnly` Keychain protection.

## TestFlight releases

AnkerCore includes a shared Release scheme, an App Store Connect export configuration, and a script that archives, signs, and uploads a unique build. Sign in to your Apple Account in **Xcode → Settings → Accounts** first, and make sure the app record's bundle ID matches the target.

```bash
export ANKERCORE_TEAM_ID=YOUR_10_CHARACTER_TEAM_ID
./scripts/upload-testflight.sh
```

The default bundle ID is `com.ankercore.app` and the default version is `1.0`. Override either when operating your own fork:

```bash
ANKERCORE_TEAM_ID=YOUR_TEAM_ID \
ANKERCORE_BUNDLE_ID=com.example.yourapp \
ANKERCORE_VERSION=1.1 \
./scripts/upload-testflight.sh
```

The script derives a unique numeric build string from the current UTC time. You can provide an explicit App Store build number with `ANKERCORE_BUILD_NUMBER=2`. Archive output stays under the ignored `build/TestFlight` directory. No App Store Connect passwords, API keys, private keys, or provisioning profiles belong in the repository.

After Apple finishes processing the upload, open the app's **TestFlight** tab in App Store Connect, create an internal testing group, add your App Store Connect user, and enable automatic distribution if desired. The TestFlight build has a different app sandbox from earlier development bundle IDs, so enter the Worker `/audio` URL and private upload token once after installing it.

The app declares `ITSAppUsesNonExemptEncryption` as `false` because its cryptography is limited to exempt encryption supplied by Apple platform frameworks (including URLSession, CryptoKit, and CommonCrypto). The upload script verifies that declaration inside the signed archive and stops before upload if it is missing, preventing future TestFlight builds from landing in **Missing Compliance**. Revisit this classification before adding any bundled or proprietary cryptographic implementation; export classification remains the distributor's responsibility.

Before external testing or App Store release, complete the App Privacy, privacy-policy URL, age-rating, export-compliance, and test-information sections in App Store Connect. AnkerCore's privacy manifest declares its app-scoped preferences access; the App Store privacy answers must also accurately describe the particular Worker, Notion workspace, AI providers, and optional webhook used by each deployment.

## 5. Connect and test

1. Export important recordings using the official Soundcore app.
2. Temporarily disable Bluetooth access for the official app in **Settings → Privacy & Security → Bluetooth** so it does not compete for the recorder connection.
3. Open the Soundcore Work case near the iPhone.
4. In AnkerCore, scan and connect to the Soundcore device.
5. Make a short, non-sensitive test recording with the physical button.
6. Press the button again to stop.
7. Watch **Automatic flow**: AnkerCore fetches the file, transcribes it, routes it, and shows a link to the resulting Notion item.
8. Use **My tasks** to open or complete extracted actions without opening Notion.

The first on-device transcription may download an Apple speech asset. If local speech or Apple Intelligence is unavailable, the status card clearly identifies the cloud fallback used.

## Routing behavior

One recording can create a meeting, multiple tasks, and multiple ideas. AnkerCore links these to the source transcript, project, client, people, and origin meeting when those facts are present. It labels each recording as:

- **Work** — employer, client, team, or primary-job duties
- **Personal Life** — home, family, health, errands, or leisure
- **Personal Work** — side business, study, creative work, or personal projects
- **Needs Review** — confidence is below the configured threshold

You can force a route by beginning a note with an explicit cue such as `Task:`, `Meeting:`, `Idea:`, `Work:`, `Personal Life:`, or `Personal Work:`.

Tasks include status, priority, owner, due date, source quote, and context. Meetings include participants, decisions, open questions, follow-up, and linked actions. Ideas include topic, why it matters, and a next experiment. Uncertain records remain visible with **Needs Review** instead of silently guessing.

## Voice identity

AnkerCore can turn a diarized transcript into lines such as `Hayden: …`, `Carter: …`, and `Peter: …`:

1. Fetch a clean recording containing at least five seconds of only one person.
2. Tap the people-and-wave icon beside that recording.
3. Enter the person's name and confirm their explicit consent.
4. Repeat with a separate solo sample for each consenting person.

The first enrollment downloads FluidAudio's diarization models. Mathematical voice embeddings are stored with complete file protection, only on that iPhone, and excluded from backup. Embeddings are never uploaded to Cloudflare, Notion, webhooks, or diagnostics. A successfully recognized name becomes part of the transcript label and therefore follows the configured transcript route to Notion/cloud/webhooks. Delete a profile from **Settings → Voice identities**. Unknown or low-confidence voices keep neutral labels such as `Speaker 1`; AnkerCore does not guess a person's identity.

## Task list, processing log, and daily focus

The authenticated `GET /tasks` endpoint powers the app's running open-task list. `POST /tasks/{page-id}/complete` verifies that the page belongs to the configured Tasks database before marking it done. The Processing Log records stages, mode, item count, destinations, and sanitized errors without copying transcript or audio content.

The iPhone app also keeps a separate per-recording processing timeline. The Relay screen shows the six most recent recordings with live states for secure fetch, on-device or fallback transcription, AI sorting, Notion routing, and optional webhook delivery. Tap a timeline to see timestamps and direct links to every returned Notion item and database. If anything fails, **Re-process recording** starts another attempt from the saved local audio, or fetches it from the connected recorder when necessary. Explicit retries resume routing with artifact-key deduplication, so completed Notion items are reused while missing items and webhook delivery are attempted again. Saved playable recordings are rediscovered after an app restart. Up to 100 timelines with 50 events each are stored locally with file protection and excluded from backup; Settings can clear this history without deleting audio or Notion records. Timeline entries never contain audio data, transcript text, credentials, webhook URLs, or cryptographic material.

The **AnkerCore Relay** home-screen widget mirrors up to 20 recent recording states and 20 open tasks from the app's protected App Group snapshot. Medium and large widgets show both lists; the small widget shows the newest recording and open-task count. Notion links are tappable. To add it, long-press the iPhone Home Screen, choose **Edit → Add Widget**, search for **AnkerCore**, and select a size. Open AnkerCore after installing an update so it can populate the first snapshot. The widget contains no audio, transcript text, tokens, webhook configuration, or voice embeddings.

## Recent Items as the control surface

Each Recent Items row is linked to all Meetings, Tasks, and Ideas extracted from that recording. The destination rows also link back through **Recent Item**. The row's **Type** selects the editable control target:

- **Meeting** + exactly one **Meeting** relation
- **Task** + exactly one **Tasks** relation
- **Idea** + exactly one **Ideas** relation

Edits to **Name**, **Area**, and **Summary** in Recent Items are copied to that selected destination by the signed Notion webhook. A Task also synchronizes **Task Status**, **Priority**, **Due**, and **Owner**. Processing **Status** remains operational metadata and is never copied. When a recording produces multiple tasks or ideas, set the matching relation to exactly one row before editing; AnkerCore intentionally refuses ambiguous multi-row updates. Changing **Type** selects another already-linked artifact—it does not move or recreate records between databases.

This is a guarded one-way edit path from Recent Items to the destination databases. Editing destination-only fields such as meeting decisions, task source quotes, or idea experiments still happens in their native database. Running **Upgrade existing AnkerCore databases** through `/setup` performs a full historical reconciliation: it groups routed artifacts by Source, repairs every typed relation and backlink, refreshes mirror fields from the selected destination, and creates a Recent row for older routed content that never received one. Reconciliation is capped at 500 rows per database per run and never deletes Notion content.

Settings includes **Test connection**, which authenticates to the Worker and performs a read-only validation of the configured Notion routing schemas. The check runs automatically after saving a connection and at launch; it never uploads audio or transcript text. Routing failures distinguish invalid credentials, network/DNS/TLS failures, Notion access loss, missing targets, rate limits, and schema mismatches without exposing response bodies or secrets.

For the production TestFlight installation, the Worker is also available at `https://ankercore-api.glucocore.app/audio` so networks that block `.workers.dev` do not interrupt processing. Existing installations configured with the legacy production hostname migrate to this custom endpoint automatically; self-hosted endpoints are never changed.

The Worker cron in `wrangler.jsonc` creates an idempotent Daily Digest at 14:00 UTC (07:00 in Arizona) with open, due, overdue, and needs-review actions. Change the cron for another local time. An authenticated `POST /digest` can generate today's digest on demand.

When a user corrects the Area on a routed Notion page, the signed Notion `page.properties_updated` webhook records the correction in Routing Feedback. Learned corrections are supplied as untrusted examples to later cloud classifications, creating an auditable feedback loop without modifying or uploading voice profiles.

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
    "database": "https://app.notion.com/p/...",
    "item_count": 3,
    "destinations": [
      {"kind": "meeting", "destination": "https://www.notion.so/...", "database": "https://app.notion.com/p/..."},
      {"kind": "task", "destination": "https://www.notion.so/...", "database": "https://app.notion.com/p/..."}
    ]
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
- Task mutations authenticate, validate page IDs, and verify database ownership before updating Notion.
- Voice enrollment requires explicit consent; embeddings are device-only, protected, excluded from backup, and user-deletable.
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
