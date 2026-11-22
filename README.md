# Hold UP

Hold UP reviews text using a local model. It shows the exact excerpt, the rule applied, and a check the reader can make. The native beta targets Apple Silicon on macOS 14 or later. The portable beta targets Apple Silicon macOS, Windows x64, and desktop Linux x64.

## Open the native Mac beta

1. Quit any older Hold UP or Claim Check instance from its menu-bar icon.
2. Open the beta DMG, drag **Hold UP** to Applications, and open it from Finder.
3. Choose **Download a local model** for the 1.36 GB Qwen3 model, or choose **Use Ollama**, click **Find installed models**, and select a model. Hold UP loads the model on your first real check and reports any compatibility error in the review panel.
4. Copy a passage and choose **Check Clipboard**. To check highlighted text directly, choose **Enable Selection Shortcut** and grant Accessibility permission, then highlight a passage and press **Control–Option–Command–K**. **Add context** accepts pasted or typed text before running the check again.

The compact built-in model supports quick flags. Source review with this model is experimental. Use a capable installed Ollama model when you want a more detailed comparison of source passages.

Settings lets you change the chords, manage models, and edit the rubric. Finding detail shows the main critique in Compact, adds one related critique in Balanced, and shows all related critiques in Expanded. The built-in engine reads GGUF files locally. The Ollama option verifies an app-owned cloud-disabled server and never starts a request on the user’s existing Ollama server. The private session reads a separate snapshot of completed models from the default Ollama store or an inherited absolute `OLLAMA_MODELS` location. Reconnect the session from Models after installing another model.

Press **Control–Option–Command–J** to check copied text directly. If selection capture is unavailable, **Preview Clipboard** fills the editor for you to review before checking.

Under **Add context**, paste an HTTPS link to a public page, then select **Load page context**. Review the fetched excerpt in the editor before checking again. Pages behind sign-in or rendered entirely by JavaScript may need manually pasted text.

Use **Find sources** for one claim. In the review panel, **⇧⌘F** opens source review. **Search Google** or **⌘↩** sends the visible query to Google in your default browser. Paste up to three public source URLs and select **Review links and citations**, or load a public page under **Add context** and choose **Review article and citations**. A review can follow up to two relevant citations. Each download can follow up to two public HTTPS redirects. The citation trail shows which article linked to each source. For paywalled or unreadable pages, paste the relevant text. Linked PDFs need selectable text and must fit the download limit.

**Review supplied context** compares the claim with the text you provided. After you load an article, **Review article and citations** uses the loaded page and leads with the strongest available quote. **Copy evidence** copies the claim, checked wording, passages, and available source links. When passages point in different directions, the card compares their stated groups, measures, and periods. Results from a smaller population can leave a broader claim unanswered. The finding detail preference controls how many additional passages are shown.

When you open Google or a source from the evidence panel, Hold UP stays available alongside your browser. Choose **Resume Current Review** from the menu bar if you lose sight of the popup. Closing it with **Esc** or its close button clears the review.

Use **Report a Problem** to prepare a report locally, or **Copy Diagnostics** for the app version, macOS version, model, and known error categories. Diagnostic output excludes claim text, clipboard contents, and source URLs.

Automatic browser selection context and timestamped video remain later milestones.

## Open the portable beta

1. Install and start [Ollama](https://ollama.com/download) with a local text model. Disable Ollama cloud features and restart Ollama. [Ollama configuration](https://docs.ollama.com/faq)
2. Open the portable Hold UP app, choose **Refresh**, and select your local model.
3. Copy a passage and choose **Paste clipboard**, or use **Ctrl–Alt–Shift–J** (**Command–Option–Shift–J** on Mac) to preview it. The in-window clipboard button is available when the shortcut is unavailable, including on some Linux desktop sessions.
4. Edit the text or add context, then check it. To compare sources, paste up to three passages and optionally add their titles and links. **Search Google** opens the editable query in your browser. **Copy evidence** copies the quotes and comparison.

The portable build reads the clipboard on request and runs inference through local Ollama. It uses pasted passages for source review. Direct highlight capture, the downloadable built-in model, and fetching linked pages and citations are features of the native Mac build.

## Build the portable app

With Node.js 24 and npm installed, run the following in the `desktop` folder:

```sh
npm ci
npm test
npm start
```

Use `npm run package:mac` on an Apple Silicon Mac for a test DMG, `npm run package:win` on Windows for an x64 installer, or `npm run package:linux` on Linux for an x64 AppImage. Packages land in `desktop/dist`. These commands create local test packages.

## Build the native Mac app

With Apple command-line development tools available, run `./build-app.sh`. The script downloads and verifies the pinned llama.cpp framework if it is absent from the vendor cache, compiles the app, and produces `build/Hold UP.app`. The app bundle uses an ad-hoc signature for local beta testing. Public distribution needs Developer ID signing and notarization.

Run `./Tests/run-tests.sh` for rubric validation, download publication and checksum handling, app-state tests, and Ollama protocol fixtures. `Tests/run-built-in-smoke.sh` uses a small local GGUF supplied by the caller or follows the test fixture instructions it prints. The HTTPS transfer test and installed Ollama checks are optional integration tests.

Run `bash Tests/run-evidence-benchmark.sh MODEL_NAME` with an installed Ollama model. The benchmark uses frozen excerpts, public source links, and constructed claims to report expected judgments, missed findings, and false flags on accurate controls. Add `--holdout` before the model name to run the separate scope examples. `--strict` fails the command when a case misses its expected result.

Run `bash Tests/run-evidence-benchmark.sh --built-in /path/to/model.gguf` to measure the first check and benchmark the bundled inference engine with a local model file.

## Mac beta download

Build the app, then run the packager to produce a local-test disk image.

```sh
./build-app.sh
./package-mac.sh --local-test 'build/Hold UP.app' build/dist
```

For a download intended for testers on other Macs, set `CLAIM_CHECK_SIGN_IDENTITY` to an installed Developer ID Application identity and `CLAIM_CHECK_NOTARY_PROFILE` to a `notarytool` profile stored in the Mac’s Keychain. Run `./package-mac.sh 'build/Hold UP.app' build/dist` to sign, notarize, staple, and verify the release DMG. The local-test DMG keeps the development signature. [Apple notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## GitHub builds and releases

The Desktop builds workflow runs on pull requests or by manual dispatch once the project is on GitHub. It tests and packages the native Mac app and the portable targets on their own operating systems. Results appear as workflow artifacts. Download and install them on each target before preparing a release. Create a draft GitHub pre-release from a version tag such as `v0.5.1` and attach the verified builds manually. Testers need repository access when it is private. [GitHub Releases guide](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

### Dependencies

- llama.cpp b12248, MIT. The framework digest and official release URL are pinned in `vendor/prepare-llama.sh`.
- Qwen3 1.7B, Apache 2.0. The download URL, size, and SHA-256 for its GGUF are pinned in `Sources/ModelStore.swift`. The app downloads weights on request.
