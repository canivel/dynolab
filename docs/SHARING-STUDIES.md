# Share and continue a study

These controls are included in the community-sharing development build. They are not in the existing 0.4.2 download.

## Publish your work

1. Open **Lab → Studies**, select your study, and click **Share study**.
2. Select the evidence entries. Add your method, finding (which may be inconclusive) and limitations. Thinking is excluded unless you choose to include it.
3. Click **Review sharing package**. Read the exact JSON and redact private text if needed. Your original notebook is unchanged.
4. Confirm that you reviewed it and have the right to share it. **Save package & open publishing** saves a file and opens Dyno Research.
5. Sign in with GitHub, upload that JSON, then review the private draft. Click Publish when ready. During beta, publication is limited to approved publisher accounts.

No background upload occurs. Raw network logs, local ports, working copies, archived entries and attachments are excluded from the sharing screen. The separate **More → Export full private notebook** action is a backup, not a publication package.

## Continue someone else's study

On a published study choose **Open in Dyno**. The app downloads only from the fixed Dyno Research host, rejects redirects, bounds the response to 1 MB and verifies the download checksum. Review its title, model, license and limitations, then import it as a new local study.

Alternatively, download the study JSON and choose **Lab → Studies → Import study**. Add the original study URL for attribution. Import preserves the original package and its hash, remaps entry IDs, and records source information in the notebook. Local entry dates represent import time. No model starts and no prompt runs during import. Choose a running model or pool before revising and executing an entry.

Package checksums detect changed bytes, not false claims. Imported thinking is model output, not a verified account of its computation. When you publish a continuation, preserve the source attribution note and license. Automatic linked publication is not implemented yet.

## Discuss research

The forum has a New/Top feed, one upvote per signed-in account per published version, and threaded comments. Upvotes indicate interest rather than scientific validity. Share concrete questions, controls and counterexamples. Discussions do not change the published evidence.
