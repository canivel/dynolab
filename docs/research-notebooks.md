# Research notebooks

Local development feature: **Lab → Studies**. Notebook data stays on this Mac. Nothing is published or sent to a journal service automatically.

![Native Studies interface displaying the recorded Typebulb study and generation settings](assets/typebulb-study/studies-settings.png)

Native view render from the saved local study. It shows the notebook and controls, not a replay of a live generation. Runtime availability is checked separately.


## Lab navigation

- **Studies**: research questions, prompt iterations and journal entries. Start here.
- **Analyze**: choose **Activations, probes & interventions** (including causal patching and SAE sandbox) or **Token probabilities**.
- **Evidence**: inspect saved/imported artifacts and add them to a study. This is an artifact viewer, not a second journal.

Use **Save to study** on a result to connect analysis to your research record.

## Start a study

Choose **New study** and enter a title, a research question and an initial hypothesis. Start with a **Plan** journal entry: describe the evidence, the comparison you will make, and what would change your mind. You can write before any model is running.

For example, investigate whether an assistant changes a release decision after a user expresses confidence without supplying new facts. Record a baseline, an incorrect-belief challenge and a correct-belief control. Keep those conditions explicit rather than treating every challenged answer as sycophancy.

## Runtime prerequisite

The Lab begins with **Step 1 · Start a model or pool** when no serving endpoint is ready. Use **Models** or **Pools**, wait for startup, then return to the Lab. Readiness checks both the local model listing and health endpoint and expires after ten seconds without a successful check. It is not based on GPU activity or a remembered port.

New notebook runs require the selected live model identity. Token analysis requires both selected endpoints when comparing. Model analysis requires a live runtime, plus the method’s existing capability and resource checks. An isolated analysis still allocates its own model copy; this prerequisite does not change that backend behavior.

Offline mode preserves access to studies, saved analyses, imported evidence, exports and planning notes. A prompt can be drafted offline, but its generation cannot run until its selected model or pool is reachable. Stopping a runtime does not erase earlier results.

## Iterate without losing earlier evidence

1. Start a model in **Models**, or create a pool in **Pools**. Select its running endpoint in the notebook.
2. Write a baseline prompt and a useful iteration title. Expand **Settings and conversation context** to inspect the system instruction, requested thinking mode, temperature, token limit and seed.
3. Choose **Save prompt draft** to freeze a version without inference, or **Run and save iteration** to submit it. A submission entry is saved before the request; a separate completion or error follows.
4. Read the final answer, finish reason and model-emitted thinking, when returned. **Saved request / response / evidence** contains the full outgoing JSON and raw endpoint response, including usage fields when the endpoint supplies them.
5. Choose **Revise prompt** to reuse the settings and conversation prefix with an editable prompt. It links the new attempt to the old entry without replacing it. **Follow up** adds the earlier user prompt and final assistant answer to the conversation. It does not pass the model's emitted thinking back as a message.
6. Select the circle on an entry to link a note to it. Use **Observation** for what happened; **Interpretation** and **Alternative explanation** for what it might mean; **Next step** for the next comparison. Corrections become new dated entries.

The requested thinking mode is not a guarantee that every backend honors it. A template may also change instructions when thinking is enabled. The notebook stores the API request and response, not a server's unexposed rendered chat template or weight revision. Pin model revisions separately and attach relevant model manifests. Thinking text is output to investigate, not proof of internal reasoning. An incomplete `<think>` block is not presented as a completed answer.

Notebook requests use the selected coordinator's loopback OpenAI-compatible chat endpoint. A pool endpoint may execute across its configured workers. The notebook does not load another copy of the model. It waits for a complete response; streaming token-by-token display is not part of this version. A chat iteration does not itself capture activations or train a probe.

## Bring in other Lab evidence

**Save to study** is available on Lab experiment results, saved token analyses and research artifacts. Pick a study to append a snapshot of the displayed result. Return to Studies and **Refresh studies** to see it. Add a note explaining how it relates to your hypothesis or a specific iteration.

Use **Attach result or file…** for images, exported JSON, papers, model manifests or representation arrays. Files are copied into the study. A result snapshot may include paths to external artifacts; those external files are not recursively copied. Attach needed tensor files explicitly for a self-contained export.

## Voice observations

Expand **Voice note · local transcription**:

- **Record voice note** asks macOS for microphone access. **Stop recording** retains the audio draft.
- Or choose **Import audio…** for an existing recording.
- **Transcribe on device** uses macOS speech recognition in the current system locale and requires on-device recognition support. There is no cloud fallback, no model download and no call to the serving LLM.
- Review and edit the transcript, then choose **Save audio and reviewed transcript**. You can save audio without a transcript when on-device recognition is unavailable.

Recording and transcription stop when leaving the notebook view. Voice drafts stay in memory while the app runs, but must be saved before quitting. Text prompt and note working copies are saved automatically. Microphone permissions and language availability must be verified on the user's Mac; recording and transcription have not been end-to-end validated in the current development session.

## Persistence, recovery and export

Studies live in `~/.mlx-dyno/notebooks/<study-id>/`:

- `study.json`: original question and hypothesis.
- `entries/`: one immutable JSON file per saved entry, with stable ID, timestamp and parent link.
- `drafts/`: automatically saved text working copies, separate from frozen evidence. Multiple app instances have separate draft files; reopening uses the latest working copy.
- `attachments/`: copied evidence and saved audio.

**Export notebook** copies the study folder. Preserve the entire folder, including attachments, when backing it up. Files are ordinary JSON and media so they remain accessible outside Dyno. This is a local research record, not a tamper-evident audit system or collaborative notebook service.

Cancellation stops the client request; the endpoint may finish work it already scheduled. If the app exits during a run, its submitted attempt stays visible without a fabricated completion. Inspect the endpoint before retrying. Read errors are displayed rather than silently dropping corrupt entries. Keep backups of valuable studies.

## Validation

Persistence tests cover reopening, immutable entries, branching context, incomplete thinking, corrupt files, autosaved working copies and copied audio bytes. The app's `--journal-check <directory> <port> <model-id>` diagnostic exercised two actual chat requests against a small local MLX model and reopened their saved history. Test outputs are labeled as workflow checks, not research findings. The local test model was stopped afterward.

### Thinking finished without an answer?

The output token limit covers both model-emitted thinking and the answer. A result with `finish_reason: length` is truncated, even if HTTP succeeded. It must not be scored as a completed benchmark response. Dyno labels this in saved results and offers **Prepare retry with more tokens** while the configured budget is below 16,384. Review the prepared prompt and run it as a new iteration; the original evidence remains unchanged. A higher budget does not guarantee completion.

Generation settings are always visible below the prompt. Set the output limit with the slider (128–16,384 tokens) or the 2K, 4K, 8K and 16K presets. The selected value is saved with each iteration. You can request Thinking Off here where the model supports it, but that changes the experimental condition. Record it separately. Missing final answers cannot be used as follow-up conversation turns, and thinking is never substituted for an answer.

### Long-running requests

Notebook runs stream model output. Live thinking and answer sections show received text while the request runs. The client allows ten minutes without incoming data and at most two hours per run. Endpoint keepalives count as incoming data; a slow active stream is no longer limited to ten minutes overall. Cancel remains available.

On timeout, cancellation or a broken stream, received text and chunks are saved as incomplete evidence. They are not a completed result and cannot be used through Follow up. Check Execution before retrying because cancelling the client does not guarantee server-side work stopped. The streamed response is assembled from saved deltas; raw chunks are retained.

Validation: seven parser/notebook tests passed, plus two live streamed completions with thinking explicitly off, saved follow-up context and reopening an isolated notebook against the local model. This validates transport and persistence, not completion of a 16K-token research run.

### Live response and archiving

Starting an iteration opens a live response window with expanded thinking and answer panels. Follow incoming text scrolls with the output; turn it off to inspect earlier text. Close returns to the notebook without cancelling. Show live thinking and answer reopens the window, and Cancel request stops the client request.

Archive on a timeline entry hides its query and result together. Show archived queries reveals hidden entries with Restore actions. Archiving preserves files and exports, does not hide later branches or notes, and is unavailable during a run. Visibility changes are stored as journal events so reopening preserves the selection.

## Recorded example: checking agreement

The [Typebulb exploratory audit](https://dynolab.dev/typebulb-study.html) records eight benchmark cases plus controls, a repeat and a thinking demonstration. All 17 responses completed. A runnable PostgreSQL check tests one narrow factual claim; the study does not estimate a model-wide sycophancy rate.

![Live thinking in a recorded native run](assets/typebulb-study/thinking-live.png)

Native response view captured during the recorded run. This is a view render, not a screen recording.

![Thinking and answer after completion](assets/typebulb-study/thinking-answer.png)

The completed run keeps model-emitted thinking separate from the final answer. See the linked audit for limitations of the model's claims.
