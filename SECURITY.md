# Security policy

Please do not open a public issue for a vulnerability that could expose recordings, transcripts, Notion content, credentials, or cryptographic material.

Report security issues privately through GitHub's **Security → Report a vulnerability** flow for this repository. Include the affected version, reproduction steps, expected impact, and any suggested mitigation. Do not include real credentials or sensitive recordings.

Before sharing diagnostic captures, inspect them and use a short, non-sensitive test recording. Rotate the Cloudflare `UPLOAD_TOKEN` and Notion integration token immediately if either may have been exposed.

Voice profiles are biometric-like sensitive data. AnkerCore requires an explicit consent confirmation before enrollment, stores embeddings only on the enrolling iPhone with complete file protection, excludes them from backup, and provides in-app deletion. Do not add voice embeddings, raw enrollment samples, speaker confidence vectors, transcripts, or names to logs, analytics, crash metadata, webhooks, or cloud requests. Unknown speakers must remain generically labeled rather than being guessed.
