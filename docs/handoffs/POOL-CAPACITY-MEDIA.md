# Capacity demonstration: capture only after verification

Latest authorization (September 11, 2026): after the large-model inference and Lab tests pass, update screenshots, docs, API/SDK and website, push the relevant repositories and publish a signed/notarized release. Preserve unpublished work. Do not publish unverified capacity claims or release if required validation fails.

## Current evidence and queue

- Website checkout: sibling `dynolab-website`, content in `public/`, locally previewed on 127.0.0.1:8771.
- `assets/pool-small-model-verified.png` is an actual recorded small-model dashboard, clearly captioned as Qwen3-0.6B, not a large-capacity proof. Preserve that distinction.
- Large download and test workflow: `~/.mlx-dyno/pool-tests/qwen235b/status.json`, `workflow.log`, `runtime.log` and eventual `response.json`.
- Candidate: Qwen/Qwen3-235B-A22B-GGUF Q4_K_M, fixed HF revision `211e807ecd6d37446a747409108783e39a04e80f`, five files totaling 142154074176 bytes. Mac physical RAM is 128 GiB; worker is RTX 5090, approximately 32 GiB VRAM.
- Pending transfer is visible in Discover through the background download observer. Do not restart/duplicate the download just to make progress.

## Acceptance before a website capacity claim

A `passed` status is a trigger to inspect evidence, not enough by itself:

1. Verify complete model identity/revision/quantization and final GGUF size. Record original manifest and SHA-256 of the model, logs and output when practical; hashing 142 GB is real I/O work and should happen after inference.
2. Record exact physical/VRAM capacities and measured available memory before loading. Express bytes consistently (GB versus GiB).
3. Inspect actual Metal and RPC model allocations and offloaded layer counts. Check for substantive CPU offload or swapping that would undermine the all-GPU capacity claim. A small allocation on both devices is not enough.
4. Confirm successful nonempty generation from the selected model with prompt, token counts, context, temperature, backend revision and timings saved.
5. Inspect fresh worker samples, matching GPU UUID, RPC process state and VRAM during the same run. Correlate independent Windows `nvidia-smi` capture when available. Report device-wide utilization honestly.
6. Retain peak system memory pressure/swap and any pressure-stop reason. Do not suppress a failed attempt or generalize from a context-512 test to larger contexts.
7. Demonstrate why weights exceed either device's capacity with measured sizes. Do not claim a measured single-device OOM unless that test was actually run. Do not intentionally crash a device just for a screenshot.

## Screenshots

Capture real native UI with model name, model-buffer allocations, both device cards, completed generation and relevant timing. Use Presentation to hide addresses, local usernames, paths, host keys and prompts that contain private information. Prefer a synthetic public prompt.

A log replay is allowed only if it is explicitly labeled recorded. `DYNO_POOL_LOG_FIXTURE=<verified-log> app/.build/release/Dyno --snapshot <output> --pools-only` renders a recorded dashboard; it is not a live-screen capture. Its local GPU chart is a separately labeled current reading, so it must not be passed off as synchronized historic telemetry.

## Video, 20–40 seconds

Prefer a continuous live native recording: show the model identity and capacities; submit the synthetic prompt; show generated text and both allocations/telemetry; finish on the measured result. Retain real waiting time or visibly label any cut/time compression. Add captions and accessible text with the same results. Never animate invented samples or turn static screenshots into a clip labeled live inference.

If live recording is unavailable, a labeled walkthrough of verified recorded results is acceptable, with a poster image and transcript. Keep the pending website state until the result has actually passed. No video element should reference a nonexistent file.

## Website update after passing

Replace the pending evidence panel in `public/index.html#pools` with exact qualified results. Update `docs/pool-guide.md` and regenerate website docs using `scripts/build-docs.py`. Include model/settings/date/hardware, source evidence summary and limitations beside media. Validate desktop/mobile, captions, alt text, local links and build. Publishing is authorized after the acceptance checks above and the full Lab suite below pass.


## Scheduled continuation, September 11

The existing heartbeat `verify-dyno-pool-capacity-demo` is set for **23:20 EDT September 11 (03:20 UTC September 12)**. Do not resume the download before then. At that time verify the downloader identity from its observer record and use the authenticated Continue control. Do not launch a second downloader. Then change the same heartbeat to every 30 minutes until validation/release completes; pause after completion or an actionable blocker.

Download observer: `~/.mlx-dyno/downloads/qwen235b-capacity-test.json`. Approximately 41.1 GB of 142.2 GB is downloaded and paused. The test workflow has an eight-hour timeout; if it expires while waiting, preserve its evidence and restart only the test workflow after completion, not the download.

## Full Lab validation required before release

Small Qwen3-0.6B Q8_0 passed pooled activations, scale/ablate/patch/steer interventions, causal patching, probes, ReLU SAE, TopK SAE, result/artifact reload and cancellation. Script: `scripts/validate-pool-research.py`. Evidence currently in `/tmp/dyno-v2-suite-summary.json`, `/tmp/dyno-v2-api-jobs`, `/tmp/dyno-v2-api-suite.log`. Both RPC and Metal captured layers are recorded; this is not large-model proof.

Repeat the suite on the large model using valid non-final layers on both backends, within memory limits. Verify ordinary generation is unchanged after an intervention/cancellation, persisted results reopen, actual native UI works, and telemetry corresponds to the run. Capture truthful media with model identity. The app probe UI also completed successfully against the small pooled model.

Native research runtime v2 source: `/private/tmp/dyno-llama-pool-spike`, reproducible patch `scripts/llama/dyno-capture.patch`, builder `scripts/llama/build-capture.py`. llama.cpp stays pinned to `5bda51bfbc62e64193221e639f6ad4e08767d760`. v2 runtime is installed in the developer cache, but release packaging must be checked to ensure end users receive/build it. App release must sign/notarize the applicable native binaries. Current installed app is a development build, not a released DMG.

The large workflow's inference-only passed state is insufficient for release. Contact email credentials and personal About content remain unconfigured; do not invent them. Audit README/site/docs for obsolete MLX-only Lab statements before publishing. Use a new version/tag after inspecting existing releases; never replace an existing release.

Small-test evidence is also preserved under `~/.mlx-dyno/pool-tests/research-v2/` (private). Native negative patch tests rejected wrong position, width and unselected layer; logits restored within 1e-5 and ordinary generation was unchanged after patch. Native UI probe and ReLU SAE runs completed and persisted. `public/assets/pool-sae-small-live.png` is an actual small-model SAE screenshot; docs caption identifies its limitations. Temporary test pool on 8982 and test Lab service on 8983 were stopped after verification; reopen an owned test pool for future validation. Download PID 630 was still stopped with 41080130656 bytes downloaded at this checkpoint.

## Latest media and explanation request

After the large-model tests pass, refresh all relevant product screenshots and experiment images across the website, README and app/API/SDK documentation using actual large-model runs. Audit image references, captions, alt text and model examples together. Never relabel existing small-model screenshots. Clearly identify any retained small-model tutorial.

Explain in plain language how one model is divided across the coordinator and worker GPUs, what each device contributes, setup steps, opening the pool in Lab, reading results and measured limitations. Show the actual large-model name and what passed. If a large-model method fails, fix and retest before capturing its screenshots or releasing.

## Resume verified, September 11 at 23:23 EDT

Authenticated Continue resumed the original PID 630 after checking its start time and command against the expected downloader. Observer bytes increased from 41080130656 to 41884916832. No new downloader was launched. The heartbeat now runs every 30 minutes for completion, validation and release work. The existing test workflow PID 4160 was still waiting for the download. Preserve it unless it times out; its inference-only result remains insufficient for release.

## Download blocked, September 12

The downloader exited on the fifth part with Hugging Face Xet CAS `File reconstruction error ... I/O error: error decoding response body`. Four verified parts (119586465312 bytes) remain. The observer reports interrupted; the test workflow reports failed_or_blocked because the downloader stopped. No inference or large-model Lab tests ran. Failure log preserved privately at `~/.mlx-dyno/pool-tests/qwen235b/download-failure-20260912.log`. The heartbeat was paused according to its failure instruction. No cached data was removed and no downloader restarted. Next recovery needs a retry of the missing fifth part using existing cache, followed by a new observer bound to that process and restarting only the validation workflow after completion. Never publish the release or capacity evidence until validation passes.

## Authorized retry started, September 12

User said “Do it” after the failure report. Started a single missing-part retry using `HF_HUB_DISABLE_XET=1` (normal HTTP), retaining four complete parts and the existing cache. No incomplete files existed before retry. Process identities are in `~/.mlx-dyno/pool-tests/qwen235b/retry-process.json`; retry script/log: `retry-missing-part.py`, `retry-download.log`. Observer is newly bound to this retry, not PID 630. Verified progress reached 120028964384 bytes. New waiting validation script `finish-retry-test.py` uses the correct retry PID/name; original failure status preserved as `status-before-retry.json`. Workflow log: `retry-workflow.log`. Heartbeat reactivated every 30 minutes. All prior large-model Lab/evidence/release gates remain.

## Download complete; preflight blocked September 12

All five parts completed. Merge succeeded, 142154073696 bytes. Do not download again. Worker probe failed: saved worker unreachable (`Host is down`) over the strict SSH path. Coordinator available memory approximately 88 GiB, below the test's 100 GiB admission threshold. No model inference or large-model Lab tests started. The waiting validation process was stopped and heartbeat paused; completed files preserved. See private `preflight-blocked.json` and `preflight-probe.log`. Next: worker awake and reachable on the selected LAN with RPC/telemetry enabled, sufficient coordinator memory, then restart only validation and complete all existing release gates.

## Worker restored; awaiting coordinator headroom

Windows now passes the device probe using newer saved pairing `feb799245f584ca88358bbb9370f538a` on port 50054. The old pool-preview configuration targets stale pairing/port 22; do not replace host keys. Correct private config is `verified-worker-config.json` in the qwen235b test directory. Probe sees MTL0 110099 MiB budget remaining and RPC0 30991 MiB free. These are not OS-free-memory guarantees. Coordinator OS available remains approximately 88 GiB; user asked to close unused apps to reach 100 GiB. Queued one `finish-ready-test.py` workflow using the newer pairing, process identity in `ready-process.json`, log `ready-workflow.log`. Heartbeat active again. No large-model inference has run yet. Do not launch duplicates or bypass the admission threshold.

## Live app test supersedes background workflow

User requested screenshots and visible execution. Stopped background workflow before generation and confirmed its child coordinator exited. Updated private pool-preview.json from the verified large-model config (backup pool-preview-before-ui.json). Native Dyno now owns the pool on8979, started through Pools UI at08:28 EDT September12. CLI PID59137, native server59145 (verify identity before signaling). Do not start duplicate coordinators or restart waiting workflow. Old status.json is historical. App Pools screen is visible with Presentation on. Actual loading screenshot `ui-loading-live.png` is NOT inference proof. `guard-ui-memory.py` watches the owned CLI and stops on <4GiB available or >2GiB swap; samples `ui-memory-samples.jsonl`. Inspect app and health8979 for readiness, run generation and full Lab suite on that existing endpoint, collect native app media. Guard must be rebound if the owned process changes. Native runtime itself enforces a ten-minute loading deadline; preserve actual failure if reached.

## Native app loading timeout

The UI-owned run ended with “Model loading exceeded ten minutes; stopping pool.” Confirmed in native Pools screen; health8979 refused and owned CLI/server exited. No generation completed and no large-model Lab tests ran. Private summary ui-test-failure.json and ui-memory-samples.jsonl preserve the failure/memory evidence. This does not establish a capacity failure or success; diagnose load/transfer progress and the fixed 600-second limit before retry. Heartbeat paused per failure instruction. Do not relabel loading screenshots as successful inference or publish release.

## Autonomous diagnosis requested

User said to figure it out until all working. Do not pause on routine fixable failures. Implemented bounded `load_timeout_seconds` (60–7200/default600), private test config3600. Native app now persists private per-run logs under ~/.mlx-dyno/pool-logs. Retried from UI but worker became unreachable on22/50054 before loading; wake packet sent to known ARP adapter, no response. User asked asynchronously to wake/confirm running worker. No active pool currently. Heartbeat every5min, quiet unchanged outage; resume when connected.

Also corrected Metal _Mapped buffer labels: mapped ranges are not resident RAM and must not be summed as physical usage. Tests added. Release CI now prepares pinned patched llama runtime and build.sh can bundle it via DYNO_POOL_RUNTIME_DIR; PoolSession prefers bundled binary for new configurations. Build running in /tmp/dyno-bundled-pool-build.log; verify result and install latest build before next live run. Existing private config still points at tested cache runtime, which is okay for current diagnostics. Preserve no-release-until-large-tests/media gates. A new guard must bind to actual owned PID on each retry; do not reuse old hardcoded PID guards.

Latest build installed and codesign verified. Bundled runtime --version reports pinned5bda51b. Private pool config now selects /Applications/Dyno.app/Contents/Resources/pool-runtime/llama-server and3600-second timeout. Python92 tests passed (5 skipped), Swift19 passed, docs generation checks passed. Full-build log /tmp/dyno-bundled-pool-build.log. Windows remained unreachable; no live model. Continue connection checks and next native UI run when available. New release packaging workflow changes have only been checked locally, not executed in GitHub CI yet.

## Worker reachable but GPU occupied, September12 10:32 EDT

SSH50054 and probe succeed, but RPC0 reports0MiB free of32606. Fresh selected-GPU telemetry reports20.2GiB used,79% utilization,552W, RPC PID37732. No Mac llama-server/coordinator is running. Evidence reconnect-probe.log and reconnect-worker-telemetry.json. Native app shows admission failure; don't bypass it. User asked asynchronously to check Windows Task Manager and close unneeded GPU workload; if only Worker running, stop/start it to clear CUDA state. Read-only Windows source /tmp/dyno-windows-client-inspect shows telemetry has no remote process listing/stop endpoint; SSH key only permits forwarding. Continue monitoring actual capacity quietly, then start through UI when ready.

## 2026-09-12 — Pool setup UX and fresh capacity diagnosis

Installed/restarted the updated native app locally. Saved pairing rows group only identical verified host key + peer + local network + account; old identity files stay intact. Selected badge, three-step automatic-save setup, collapsed discovery/advanced settings, and prominent actionable errors verified in the actual app. 30 pool Python tests and 19 Swift tests pass; signed app verifies.

Fresh SSH/RPC device probes succeed through the saved identity, but RPC reports 0 MiB free on the RTX 5090. Latest prior telemetry sample reports 1% utilization and 986710016 bytes used out of 34190917632. These disagree; no inference attempt should bypass the allocator reading. Probe now fails explicitly with the zero-memory diagnosis and worker RPC stop/start recovery instructions. This is not a pairing failure. The native app remains open on Pools showing this result. Large-model inference is still unverified. Remote telemetry is read-only; the paired SSH identity allows forwarding rather than arbitrary worker process control.

## Current native loading run, September12 10:57 EDT

User says pool working after restarting worker. Verified native CLI65240 owns llama65248 and SSH65246; health8979 still503 Loading model. Do not launch another pool/probe. Log pool-C02AF9A5-1442-455D-BBAB-A92B88032275.log. Transfer progressing ~24MB/s, ~8GB each direction observed; not stalled. RPC buffer30841MiB; Mac available~20.8GiB, zero swap. New guard-current.py checks exact CLI command/start time before signaling and records ui-current-memory-samples.jsonl, running exec session17150. Do not reuse old guard. Heartbeat updated to monitor this run and continue full validation after readiness. Allocation/loading is not generation proof. No new release/media published.

## Large model reached readiness but Metal execution failed

At11:23 EDT loading completed after32m56s. /props verified Qwen3-235B-A22B-Q4_K_M and capture runtime2. First capture request failed HTTP500; native log explicitly reports kIOGPUCommandBufferCallbackErrorOutOfMemory and requires backend recreation. No successful generation. Stopped the owned pool through UI. Suspected oversized Metal mmap range135563MiB exceeds107.5GiB budget despite remote weights; runtime now uses --no-mmap to allocate per-backend tensors, pending live retest. No system memory-limit overrides. Added UI detection of Metal backend failure so it no longer counts these failed requests as completed or shows Ready. Building latest app in /tmp/dyno-no-mmap-build.log, tests /tmp/dyno-metal-test.log. Lab test service8983 is running with private qwen235b/lab-jobs, exec20414. No duplicate model should be started. Rebind memory guard after UI restart. Large model acceptance remains pending.

Retry now running from installed native app: CLI70430/server70438, logfile pool-8AC9AD84-755A-4DEE-801B-DEF6BE2B4936.log. Correct pinned flag is --load-mode none (not legacy --no-mmap). Real allocations now MTL0104387.97MiB, RPC030841.15MiB, CPU333.84MiB. This removes oversized mapping, not yet execution proof. guard-explicit.py checks70430identity, exec42499, ui-explicit-memory-samples.jsonl. 30Python/20Swift tests passed, signed bundle verified. Monitor existing run only; normal generation then capture n_predict1/layers4,80, then fullsuite. Labservice8983 remainsrunning. Do not publish until verified.

## Targeted output placement trial September12 11:46 EDT

Explicitallocation retry stoppedbyguard atswap2108MiB; compressor~78GiB. Preserve ui-explicit-memory-samples.jsonl. No successfulinference. GGUFReader inspection proves output.weight atoffset6004320, output_norm516509280, whileblk22~34.6GB. Output onMetal therefore made mmap spanremoteweights. Newtrial uses --load-mode mmap --override-tensor ^output.*=CPU (about487MiB CPUoutput), notglobalno-mmap. Installedsignedapp; actualCLI71879/server71887, poollog364F438F-F08F-49FC-B5C1-C2E4ACFAE515. Guard-output.py exec17512 exactidentity, available<4GiB or NEWswap>2GiB aboveprestartbaseline (~2100MiB alreadyusedbyOS afteroldrun). Baseline capturedbeforestart output-placement-baseline.json; do notclaimzeroswap. New samples ui-output-memory-samples.jsonl. Continueexistingrun, checkMetalrange thennormalgeneration andallLabmethods. No model download or release.

## Large generation and API research suite passed September12 12:38 EDT

Existing pool71879/71887 remains ready8979; loading49m22s. Normalgeneration12tokens returned Paris.. at9.47tok/s (shorttest), actualcapture layer4RPC/layer80Metal succeeded. Fullresearch summary qwen235b/full-research/summary.json: inspect,scale,ablate,patch,steer,patch_sweep,probe,ReLUSAE,TopKSAE,cancellationpassed. Restored/noopcontrols verified bysuite; post-suite-generation.json contentidenticalbaseline andnocaptureleak. Ninecompletedjobs copiedwithoutoverwrite into ~/.mlx-dyno/lab fornativehistory. UIpool Generate128tokenrequestran, actualscreenshotpool-large-live.png needsreview.

Remaining nativeUIbug: LabResources availableafterreserve0 disablesRun despiteAPIpassing; inspect reserve subtraction aftermin(OSfree,Metalheadroom), whichdouble-reservesOSmarginfromMetalbudget. Do notweakenactualmemoryguard. Needcorrectestimate andvalidateUI withoutunnecessarilystopping49min-loadedpool. Startlabclickednative service8980, verifyhistory. Allnewmedia/docs/website/releaseworkstillpending. Guard-output.py active; memory~8GiBavailable,swap1.66GiBbelowbaseline2.1GiB. No releaseyet. Existing smallmodeltestsarenotlargeUIproof.

## Lab reserve fix and native probe rerun September12 12:48 EDT

LabResources now subtracts OS reserve before min with Metalheadroom; previously reserved OS margin from alreadybudgetedMetal. Added regression checks preserving lowRAM block;21Swiftpassed. Built app/build-pairing/Dyno.app, /tmp/dyno-reserve-build.log. NOT installed/restarted owner because poolload49min. Existing old app UI successfully reran two-layer probe job924f6f0f75d9448c859916fa0da8c325 atservice8980, completed withRPC4/Metal80; savedhistory reloadworks. Actualprivatecapture probe-native-live.png includes oldmemorywarning, notpublicationready. NeedverifyupdatedUI duringhotresidentstate (oldbuild returns0headroom afterrun). TemporarysecondappPID80812 wasclosed explicitly; owner71862+pool71879/71887 retained.

Snapshot renderer --lab-only initially fails toselectstoredjob because viewstate startsinspect; --public filterslabentirely. DoNOTuse resultingblankcapture asproof. Nativehistory selection works. Needfixsnapshotrestoreoperation or use realUI updated QA app with separatebundleidentifier toallowCUAselection whileoldappowns pool. Readactualreservememory numbers beforefurtherchanges; don'trelax estimates arbitrarily. DocsREADME/poolguide/pool-lab now truthfullargeAPIsuccess nativeUIpending, localonly. Websiteupdate/releasepending.

## Updated UI verified; large media added locally September12 13:00 EDT

Created ad-hoc QA clone /tmp/Dyno-QA.app, bundledev.dynolab.qa, PID82082, window1553. Pool owneroriginal71862 unchanged; pool71879/71887 stillready. CUAgetApp('dev.dynolab.qa') reliably selectsQA. Updatedreserve fix passed nativeactivation, two-deviceprobe andReLUSAE reruns; post-runavailable3.4–3.9GiB andRunremainedenabled. Savedresultreloadverified. Probe12:55:36, SAEjob1e2d235cf440482a886afdba56c66dac12:57:06. NativeQAhas noownedpool; don'tquitoriginalowner.

Real screenshots visuallyreviewed: qwen235b/probe-qa-live.png,sae-qa-live.png,pool-large-overview.png. Copiedto websitepublic/assets/pool-probe-235b-live.png,pool-sae-235b-live.png,pool-235b-live.png andupdatedhomepagepoolsectionwithtestedcapacity+Labresults andlimitations. NoIPs/paths intheseimages. NativeQA screenshot sameactualproductviews; nofabricatedresults. Website8tests/buildpassed. New128tokenmediageneration completed10.12tok/s, evidence media-generation.json; this isnotgeneralbenchmark. Sourcefix stillonlyQA/build-pairing, originalinstalledUIoldreserve; installfinalbuildafterremainingverification withoutneedless49minreload.

Remaining: updateallrelevantdocsSDKAPIwebsiteexamples/media, getmore nativeintervention/causal/TopK captures andvideo, browserQA desktop/mobile/reducedmotion, thoroughreleasechecks/signing/notarization/CI, thenauthorizedpush/release. FixsnapshotLabrestorestateandzero0tok/sfromsingle-tokenresearchpasses ifneeded. No releasepublished. QAappcanremainavailableforuser; primarypoolownerremainsrunning. Do not repeatlargeAPIsuitewithoutnewchangeswarrantingit.
