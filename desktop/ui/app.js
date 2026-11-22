"use strict";

const api = window.claimCheck;
const byId = id => document.getElementById(id);
const claim = byId("claim");
const context = byId("context");
const model = byId("model");
const query = byId("query");
const sourceFields = byId("source-fields");
const checkResults = byId("check-results");
const evidenceResults = byId("evidence-results");
const checkStatus = byId("check-status");
const evidenceStatus = byId("evidence-status");
const modelStatus = byId("model-status");
const modelHelp = byId("model-help");
const ruleStatus = byId("rule-status");
const searchStatus = byId("search-status");
const cancelButtons = [...document.querySelectorAll("[data-cancel]")];
const limits = { claim: 4800, context: 3200, sourceText: 30000, sourceTitle: 200, sourceLink: 2048, sources: 3 };
const dimensions = {
  figure: "Figure", scope: "Scope", time: "Time period", baseline: "Baseline",
  measure: "What was measured", cause: "Cause", attribution: "Attribution", assertion: "Assertion"
};
const relations = {
  supports: "Supports", narrower: "Narrower scope", challenges: "Challenges", mixed: "Mixed", unclear: "Unclear"
};
const sourceStates = {
  reviewed: "Relevant passage found", no_match: "No relevant passage found", failed: "Source review failed"
};

let settings = { model: "", rules: [] };
let ready = false;
let refreshing = false;
let saving = false;
let pasting = false;
let searching = false;
let activeTask = null;
let customQuery = false;

function element(tag, value, className) {
  const node = document.createElement(tag);
  if (value) node.textContent = value;
  if (className) node.className = className;
  return node;
}

function button(label, action, className) {
  const node = element("button", label, className);
  node.type = "button";
  node.addEventListener("click", action);
  return node;
}

function status(node, message, tone = "") {
  node.dataset.tone = tone;
  node.textContent = message;
}

function errorText(error, fallback) {
  if (!error?.message) return fallback;
  return error.message.replace(/^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/, "").slice(0, 500) || fallback;
}

function setConnection(message, state) {
  const badge = byId("local-status");
  badge.textContent = message;
  badge.dataset.state = state;
}

function syncControls() {
  const busy = Boolean(activeTask);
  const modelBusy = !ready || refreshing || saving;
  const canReview = !modelBusy && !busy && !pasting && Boolean(model.value);
  byId("check").disabled = !canReview;
  byId("compare").disabled = !canReview;
  byId("paste").disabled = !ready || busy || pasting;
  byId("search").disabled = !ready || searching;
  byId("refresh").disabled = modelBusy || busy;
  model.disabled = modelBusy || busy || model.options.length < 2;
  byId("save-rules").disabled = !ready || busy || saving || refreshing;
  byId("add-source").disabled = busy || sourceFields.children.length >= limits.sources;
  claim.readOnly = busy;
  context.readOnly = busy;
  for (const field of sourceFields.querySelectorAll("[data-source]")) field.readOnly = busy;
  for (const remove of sourceFields.querySelectorAll("[data-remove-source]")) remove.disabled = busy;
  for (const toggle of byId("rules").querySelectorAll("input")) toggle.disabled = busy || saving;
  for (const cancel of cancelButtons) {
    cancel.hidden = activeTask?.kind !== cancel.dataset.cancel;
    cancel.disabled = Boolean(activeTask?.stopping);
  }
}

function clearResults(container) {
  container.replaceChildren();
  container.hidden = true;
}

function updateClaim() {
  claim.removeAttribute("aria-invalid");
  if (!customQuery || !query.value.trim()) {
    query.value = claim.value.trim().replace(/\s+/g, " ").slice(0, 240).trimEnd();
    customQuery = false;
  }
  clearResults(checkResults);
  clearResults(evidenceResults);
  status(checkStatus, "");
  status(evidenceStatus, "");
}

function previewClipboard(value) {
  if (activeTask) {
    status(activeTask.statusNode, "A review is running. Cancel or wait for it to finish before pasting.");
    return;
  }
  if (!value.trim()) {
    status(checkStatus, "The clipboard has no text to paste.", "error");
    return;
  }
  claim.value = value;
  updateClaim();
  claim.focus();
  claim.setSelectionRange(0, 0);
  status(checkStatus, "Pasted from the clipboard. Review the text before checking.");
}

async function pasteClipboard() {
  pasting = true;
  syncControls();
  try {
    previewClipboard(await api.clipboard());
  } catch (error) {
    status(checkStatus, errorText(error, "Couldn’t read the clipboard."), "error");
  } finally {
    pasting = false;
    syncControls();
  }
}

async function refreshModels() {
  refreshing = true;
  status(modelStatus, "");
  modelHelp.hidden = true;
  setConnection("Checking Ollama", "waiting");
  syncControls();
  try {
    const installedModels = await api.models();
    const prompt = installedModels.length ? "Choose an installed model" : "No installed models";
    model.replaceChildren(new Option(prompt, ""), ...installedModels.map(name => new Option(name, name)));
    if (installedModels.includes(settings.model)) model.value = settings.model;
    if (!installedModels.length) {
      setConnection("Model setup needed", "attention");
      modelHelp.hidden = false;
    } else {
      setConnection("Ollama connected", "ready");
      if (settings.model && !model.value) status(modelStatus, "Choose an installed model to resume checking.");
    }
  } catch (error) {
    model.replaceChildren(new Option("Models unavailable", ""));
    setConnection("Ollama needs attention", "attention");
    status(modelStatus, errorText(error, "Couldn’t find installed Ollama models."), "error");
    modelHelp.hidden = false;
  } finally {
    refreshing = false;
    syncControls();
  }
}

async function saveSettings(next, feedback, onSuccess) {
  saving = true;
  status(feedback, "");
  syncControls();
  try {
    await api.saveSettings(next);
    settings = next;
    onSuccess();
  } catch (error) {
    const previous = [...model.options].some(option => option.value === settings.model) ? settings.model : "";
    model.value = previous;
    status(feedback, errorText(error, "Couldn’t save settings."), "error");
  } finally {
    saving = false;
    syncControls();
  }
}

function showRules() {
  byId("rule-panel").hidden = !settings.rules.length;
  byId("rules").replaceChildren(...settings.rules.map(rule => {
    const label = element("label", "", "rules-item");
    const toggle = element("input");
    toggle.type = "checkbox";
    toggle.checked = rule.enabled;
    const text = element("span");
    text.append(element("strong", rule.name), element("span", rule.criterion, "rule-description"));
    label.append(toggle, text);
    return label;
  }));
}

function updateSourceRows() {
  [...sourceFields.children].forEach((row, index) => {
    const name = `Source ${index + 1}`;
    row.querySelector("legend").textContent = name;
    const remove = row.querySelector("[data-remove-source]");
    remove.hidden = sourceFields.children.length === 1;
    remove.setAttribute("aria-label", `Remove ${name.toLowerCase()}`);
  });
  byId("add-source").hidden = sourceFields.children.length >= limits.sources;
  syncControls();
}

function addSource(focus) {
  const row = byId("source-template").content.firstElementChild.cloneNode(true);
  row.querySelector("[data-remove-source]").addEventListener("click", () => {
    const target = row.nextElementSibling || row.previousElementSibling;
    row.remove();
    clearResults(evidenceResults);
    status(evidenceStatus, "");
    updateSourceRows();
    target.querySelector("textarea").focus();
  });
  sourceFields.append(row);
  updateSourceRows();
  if (focus) row.querySelector("textarea").focus();
}

function httpUrl(value) {
  try {
    const url = new URL(value);
    if (["http:", "https:"].includes(url.protocol) && !url.username && !url.password) return url.href;
  } catch {
    return null;
  }
  return null;
}

function invalid(field, feedback, message) {
  field.setAttribute("aria-invalid", "true");
  status(feedback, message, "error");
  field.focus();
  return null;
}

function readClaim(feedback) {
  const text = claim.value.trim();
  if (!text) return invalid(claim, feedback, "Enter a claim or passage first.");
  if (text.length > limits.claim) return invalid(claim, feedback, "Shorten the claim to 4,800 characters or fewer.");
  return text;
}

function readSources() {
  const sources = [];
  for (const row of sourceFields.children) {
    const textField = row.querySelector('[data-source="text"]');
    const urlField = row.querySelector('[data-source="url"]');
    const titleField = row.querySelector('[data-source="title"]');
    const text = textField.value.trim();
    const title = titleField.value.trim();
    const link = urlField.value.trim();
    if (!text && !title && !link) continue;
    if (!text) return invalid(textField, evidenceStatus, "Paste text from this source to compare it with the claim.");
    if (text.length > limits.sourceText) {
      return invalid(textField, evidenceStatus, "Shorten this source to 30,000 characters or fewer.");
    }
    if (title.length > limits.sourceTitle) {
      return invalid(titleField, evidenceStatus, "Shorten this title to 200 characters or fewer.");
    }
    const url = link && httpUrl(link);
    if (link && (!url || url.length > limits.sourceLink)) {
      return invalid(urlField, evidenceStatus, "Enter an HTTP or HTTPS link without sign-in details, up to 2,048 characters.");
    }
    sources.push({ text, ...(title && { title }), ...(url && { url }) });
  }
  if (!sources.length) return invalid(sourceFields.querySelector("textarea"), evidenceStatus, "Paste at least one source passage.");
  return sources;
}

async function review(kind, statusNode, progress, perform, showResults) {
  if (activeTask) return;
  const task = { kind, statusNode, stopping: false };
  activeTask = task;
  status(statusNode, progress);
  syncControls();
  const cancel = cancelButtons.find(node => node.dataset.cancel === kind);
  cancel.focus();
  try {
    const result = await perform();
    if (task.stopping) return;
    status(statusNode, "");
    showResults(result);
  } catch (error) {
    if (!task.stopping) status(statusNode, errorText(error, "The local review failed. Try again."), "error");
  } finally {
    activeTask = null;
    if (task.stopping) status(statusNode, "Review canceled.");
    const restoreFocus = document.activeElement === cancel || document.activeElement === document.body;
    syncControls();
    if (restoreFocus) byId(kind === "check" ? "check" : "compare").focus();
  }
}

async function cancelReview() {
  const task = activeTask;
  if (!task || task.stopping) return;
  task.stopping = true;
  status(task.statusNode, "Canceling review…");
  syncControls();
  try {
    await api.cancel();
  } catch (error) {
    if (activeTask !== task) return;
    task.stopping = false;
    status(task.statusNode, errorText(error, "Couldn’t cancel the review. It is still running."), "error");
    syncControls();
  }
}

function presentResults(container, header, ...content) {
  const heading = header.querySelector("h2");
  heading.tabIndex = -1;
  container.replaceChildren(header, ...content);
  container.hidden = false;
  heading.focus();
}

function renderCheck(result) {
  const copy = {
    findings: ["What to check", ""],
    no_flags: ["No flags in this passage", "Verify the claim against a source if you need to confirm it."],
    needs_context: ["More context needed", "Add the surrounding text or background and try again."]
  };
  const [title, explanation] = copy[result.outcome];
  const header = element("div", "", "result-header");
  header.append(element("h2", title));
  const findings = result.findings.map(finding => {
    const card = element("article", "", "result-card");
    card.append(element("h3", finding.rule));
    if (finding.quote) card.append(element("blockquote", finding.quote));
    if (finding.reason) card.append(element("p", finding.reason));
    if (finding.verify) {
      const followUp = element("div", "", "next-check");
      followUp.append(element("strong", "Next check"), element("p", finding.verify));
      card.append(followUp);
    }
    return card;
  });
  if (explanation) findings.unshift(element("p", explanation, "result-summary"));
  presentResults(checkResults, header, ...findings);
}

function passageLabel(passage) {
  const relation = relations[passage.relation] || passage.relation || "Unclear";
  const dimension = dimensions[passage.dimension] || passage.dimension;
  return [relation, dimension].filter(Boolean).join(" · ");
}

function evidenceText(checkedClaim, result) {
  const lines = ["Hold UP — Source comparison", "", "Claim", checkedClaim];
  if (result.hasConflict) lines.push("", "Sources reported conflicting evidence.");
  for (const [index, source] of result.sources.entries()) {
    lines.push("", source.title || `Source ${index + 1}`);
    if (source.url) lines.push(source.url);
    lines.push(sourceStates[source.status]);
    if (source.error) lines.push(source.error);
    for (const passage of source.passages) {
      lines.push("", passageLabel(passage));
      if (passage.quote) lines.push("Source quote", passage.quote);
      if (passage.claimQuote) lines.push("Claim wording", passage.claimQuote);
      if (passage.explanation) lines.push(passage.explanation);
    }
  }
  return lines.join("\n");
}

function renderEvidence(result, checkedClaim) {
  const header = element("div", "", "result-header");
  const feedback = element("p", "", "status");
  feedback.setAttribute("role", "status");
  const copy = button("Copy evidence", async () => {
    copy.disabled = true;
    try {
      await api.copyEvidence(evidenceText(checkedClaim, result));
      status(feedback, "Evidence copied.");
    } catch (error) {
      status(feedback, errorText(error, "Couldn’t copy the evidence."), "error");
    } finally {
      copy.disabled = false;
    }
  });
  header.append(element("h2", "Source comparison"), copy);
  const failedCount = result.sources.filter(source => source.status === "failed").length;
  const summary = [];
  if (result.hasConflict) summary.push("Sources reported conflicting evidence.");
  if (failedCount) summary.push(failedCount === 1 ? "One source couldn’t be reviewed." : `${failedCount} sources couldn’t be reviewed.`);
  const cards = result.sources.map((source, index) => {
    const card = element("article", "", "result-card");
    const sourceStatus = element("p", sourceStates[source.status], "source-status");
    sourceStatus.dataset.state = source.status;
    card.append(element("h3", source.title || `Source ${index + 1}`), sourceStatus);
    if (source.error) card.append(element("p", source.error));
    const url = httpUrl(source.url);
    if (url) {
      const link = element("div", "", "source-url");
      link.append(element("span", url), button("Open source", async () => {
        try {
          await api.openSource(url);
        } catch (error) {
          status(feedback, errorText(error, "Couldn’t open the source."), "error");
        }
      }));
      card.append(link);
    }
    for (const passage of source.passages) {
      const detail = element("div", "", "passage");
      detail.append(element("p", passageLabel(passage), "relation"));
      if (passage.quote) detail.append(element("p", "Source quote", "quote-label"), element("blockquote", passage.quote));
      if (passage.claimQuote) detail.append(element("p", "Claim wording", "quote-label"), element("blockquote", passage.claimQuote));
      if (passage.explanation) detail.append(element("p", passage.explanation));
      card.append(detail);
    }
    return card;
  });
  if (summary.length) {
    const note = element("p", summary.join(" "), "result-summary");
    note.dataset.conflict = String(result.hasConflict);
    cards.unshift(note);
  }
  presentResults(evidenceResults, header, feedback, ...cards);
}

byId("check-form").addEventListener("submit", event => {
  event.preventDefault();
  if (byId("check").disabled) return;
  const text = readClaim(checkStatus);
  if (!text) return;
  const background = context.value.trim();
  if (background.length > limits.context) {
    byId("context-panel").open = true;
    invalid(context, checkStatus, "Shorten the context to 3,200 characters or fewer.");
    return;
  }
  clearResults(checkResults);
  review("check", checkStatus, "Checking with the local model…",
    () => api.check({ claim: text, context: background, model: model.value, rules: settings.rules }), renderCheck);
});

byId("sources-form").addEventListener("submit", event => {
  event.preventDefault();
  if (byId("compare").disabled) return;
  const text = readClaim(evidenceStatus);
  if (!text) return;
  const sources = readSources();
  if (!sources) return;
  clearResults(evidenceResults);
  review("evidence", evidenceStatus, "Comparing the pasted source text…",
    () => api.evidence({ claim: text, model: model.value, sources }), result => renderEvidence(result, text));
});

byId("search-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (byId("search").disabled) return;
  const terms = query.value.trim();
  if (!terms) {
    invalid(query, searchStatus, "Enter search terms first.");
    return;
  }
  if (terms.length > limits.claim) {
    invalid(query, searchStatus, "Shorten the search terms to 4,800 characters or fewer.");
    return;
  }
  searching = true;
  syncControls();
  status(searchStatus, "");
  try {
    await api.search(terms);
  } catch (error) {
    status(searchStatus, errorText(error, "Couldn’t open Google."), "error");
  } finally {
    searching = false;
    syncControls();
  }
});

byId("rule-form").addEventListener("submit", event => {
  event.preventDefault();
  if (byId("save-rules").disabled) return;
  const toggles = [...byId("rules").querySelectorAll("input")];
  const rules = settings.rules.map((rule, index) => ({ ...rule, enabled: toggles[index].checked }));
  if (!rules.some(rule => rule.enabled)) {
    status(ruleStatus, "Enable at least one rule to save.", "error");
    return;
  }
  saveSettings({ model: settings.model, rules }, ruleStatus, () => {
    clearResults(checkResults);
    status(ruleStatus, "Rules saved.");
  });
});

model.addEventListener("change", () => {
  saveSettings({ ...settings, model: model.value }, modelStatus, () => {
    clearResults(checkResults);
    clearResults(evidenceResults);
  });
});

claim.addEventListener("input", updateClaim);
context.addEventListener("input", () => {
  context.removeAttribute("aria-invalid");
  clearResults(checkResults);
  status(checkStatus, "");
});
sourceFields.addEventListener("input", event => {
  event.target.removeAttribute("aria-invalid");
  clearResults(evidenceResults);
  status(evidenceStatus, "");
});
query.addEventListener("input", () => {
  customQuery = true;
  query.removeAttribute("aria-invalid");
  status(searchStatus, "");
});
byId("rules").addEventListener("change", () => status(ruleStatus, ""));
byId("refresh").addEventListener("click", refreshModels);
byId("paste").addEventListener("click", pasteClipboard);
byId("add-source").addEventListener("click", () => addSource(true));
for (const cancel of cancelButtons) cancel.addEventListener("click", cancelReview);
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && activeTask) {
    event.preventDefault();
    cancelReview();
  }
});

async function initialize() {
  addSource(false);
  try {
    api.onClipboard(previewClipboard);
    const initial = await api.init();
    settings = { model: initial.model, rules: initial.rules };
    showRules();
    const shortcut = byId("shortcut");
    if (initial.shortcutAvailable && initial.shortcut) {
      const key = initial.shortcut.replace("CommandOrControl", navigator.platform.startsWith("Mac") ? "Command" : "Ctrl");
      shortcut.append(element("kbd", key), " previews the clipboard.");
    } else {
      shortcut.textContent = "Clipboard shortcut unavailable in this desktop session.";
    }
    shortcut.hidden = false;
    ready = true;
    await refreshModels();
  } catch (error) {
    setConnection("Setup unavailable", "attention");
    model.replaceChildren(new Option("Model settings unavailable", ""));
    status(modelStatus, api ? errorText(error, "Couldn’t load Hold UP settings.") : "Open this window from the Hold UP desktop app.", "error");
    syncControls();
  }
}

initialize();
