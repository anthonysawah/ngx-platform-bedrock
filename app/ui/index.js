/* eslint-env browser */

const apiUrl = (window.NGX_API_URL || "").replace(/\/$/, "");

// Polling cadence: 2s. Schema caps duration at 180s; allow 4 minutes total
// before giving up so a slow Bedrock summary doesn't trigger a false timeout.
const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 240_000;
const TICK_INTERVAL_MS = 1000;
// Toast threshold: only celebrate "Aurora scaled" when peak rises this far
// above starting. CloudWatch ACU is bucketed at 1-min granularity (ADR-008),
// so anything below ~0.3 may just be normal sub-ACU jitter.
const SCALE_TOAST_DELTA = 0.3;
// Visual pause on the "Summarizing" pill so users see all four phases.
const SUMMARIZE_FLASH_MS = 700;
const TERMINAL_STATUSES = new Set([
  "complete",
  "bedrock_error",
  "workload_error",
  "timeout",
]);

const form = document.getElementById("prompt-form");
const promptInput = document.getElementById("prompt");
const submitBtn = document.getElementById("submit-btn");
const statusEl = document.getElementById("status");
const phaseStepper = document.getElementById("phase-stepper");
const parsedSpecCard = document.getElementById("parsed-spec-card");
const parsedSpecPrompt = document.getElementById("parsed-spec-prompt");
const parsedSpecGrid = document.getElementById("parsed-spec-grid");
const liveTiles = document.getElementById("live-tiles");
const tileRpsValue = document.getElementById("tile-rps-value");
const tileAcu = document.getElementById("tile-acu");
const tileAcuValue = document.getElementById("tile-acu-value");
const tileElapsedValue = document.getElementById("tile-elapsed-value");
const resultSection = document.getElementById("result");
const clampBanner = document.getElementById("clamp-banner");
const metaEl = document.getElementById("meta");
const summaryEl = document.getElementById("summary");
const chartCanvas = document.getElementById("chart");
const recentList = document.getElementById("recent-runs");
const refreshRunsBtn = document.getElementById("refresh-runs-btn");
const toastContainer = document.getElementById("toast-container");

const PHASE_ORDER = ["parse", "run", "summarize", "complete"];

let chart = null;
let elapsedTimer = null;
let renderedSampleCount = 0;
let scaleToastShown = false;
let runStartingAcu = null;

// ---------- form submit ----------

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const prompt = promptInput.value.trim();
  if (!prompt) return;

  resetRunState();
  setPhase("parse");
  showStepper(true);
  setStatus("running", "Parsing intent…");
  submitBtn.disabled = true;

  let runId = null;
  let startedAt = null;

  try {
    const created = await api("POST", "/workloads", { prompt });
    runId = created.run_id;
    startedAt = Date.now();

    renderParsedSpec(prompt, created.spec || {});
    parsedSpecCard.hidden = false;

    setPhase("run");
    showLiveTiles();
    startElapsedTimer(startedAt);
    initEmptyChart();
    showResultSection();
    renderClampBanner(created.spec || {});

    setStatus("running", `Running… target ${created.spec?.duration_seconds ?? "?"}s.`);

    const final = await pollUntilTerminal(runId, startedAt);
    stopElapsedTimer();

    if (final.status === "complete") {
      // Brief flash on "Summarizing" so all four phases are visible.
      setPhase("summarize");
      await sleep(SUMMARIZE_FLASH_MS);
      setPhase("complete");
      renderRunFinal(final);
      setStatus("complete", `Run ${runId.slice(0, 8)}… complete in ${elapsedSec(startedAt)}s.`);
      loadRecent();
    } else {
      setPhaseError();
      const reason = final.error || `status ${final.status}`;
      setStatus("error", `Run ended: ${reason}`);
    }
  } catch (err) {
    stopElapsedTimer();
    setPhaseError();
    setStatus("error", err.message);
  } finally {
    submitBtn.disabled = false;
  }
});

// ---------- polling + live updates ----------

async function pollUntilTerminal(runId, startedAt) {
  while (Date.now() - startedAt < POLL_TIMEOUT_MS) {
    await sleep(POLL_INTERVAL_MS);
    const record = await api("GET", `/workloads/${runId}`);
    onPollTick(record);
    if (TERMINAL_STATUSES.has(record.status)) {
      return record;
    }
  }
  throw new Error("Polling timed out before run completed.");
}

function onPollTick(record) {
  const metrics = record.metrics || [];
  if (metrics.length > renderedSampleCount) {
    appendNewSamples(metrics);
    renderedSampleCount = metrics.length;
  }

  const last = metrics.length ? metrics[metrics.length - 1] : null;
  if (last) {
    if (runStartingAcu === null && last.current_acu) {
      runStartingAcu = last.current_acu;
    }
    updateTiles(last);
    maybeShowScaleToast(last);
  }
}

function appendNewSamples(metrics) {
  if (!chart) return;
  const newSamples = metrics.slice(renderedSampleCount);
  for (const m of newSamples) {
    chart.data.labels.push(`t+${m.second_offset}s`);
    chart.data.datasets[0].data.push(m.rows_inserted);
    chart.data.datasets[1].data.push(m.current_acu);
  }
  chart.update("none");
}

function updateTiles(sample) {
  tileRpsValue.textContent = numberFmt(sample.rows_inserted);
  pulseTile("tile-rps");

  if (sample.current_acu !== undefined && sample.current_acu !== null) {
    tileAcuValue.textContent = sample.current_acu.toFixed(2);
    setAcuLevel(sample.current_acu);
    pulseTile("tile-acu");
  }
}

function setAcuLevel(acu) {
  tileAcu.classList.remove("acu-low", "acu-mid", "acu-high");
  if (acu >= 3) tileAcu.classList.add("acu-high");
  else if (acu >= 1.5) tileAcu.classList.add("acu-mid");
  else tileAcu.classList.add("acu-low");
}

function pulseTile(id) {
  const el = document.getElementById(id);
  if (!el) return;
  el.classList.remove("pulse");
  // Force reflow so the animation re-fires when the same value lands twice.
  void el.offsetWidth;
  el.classList.add("pulse");
}

function maybeShowScaleToast(sample) {
  if (scaleToastShown) return;
  if (runStartingAcu === null) return;
  if (sample.current_acu - runStartingAcu < SCALE_TOAST_DELTA) return;
  showToast(`Aurora scaled to ${sample.current_acu.toFixed(1)} ACU`);
  scaleToastShown = true;
}

// ---------- elapsed counter ----------

function startElapsedTimer(startedAt) {
  stopElapsedTimer();
  tileElapsedValue.textContent = "0s";
  elapsedTimer = setInterval(() => {
    tileElapsedValue.textContent = `${elapsedSec(startedAt)}s`;
  }, TICK_INTERVAL_MS);
}

function stopElapsedTimer() {
  if (elapsedTimer) {
    clearInterval(elapsedTimer);
    elapsedTimer = null;
  }
}

// ---------- phase stepper ----------

function setPhase(phase) {
  const idx = PHASE_ORDER.indexOf(phase);
  for (const step of phaseStepper.querySelectorAll(".phase-step")) {
    const i = PHASE_ORDER.indexOf(step.dataset.phase);
    step.classList.remove("active", "done", "error");
    if (i < idx) step.classList.add("done");
    else if (i === idx) step.classList.add("active");
  }
}

function setPhaseError() {
  for (const step of phaseStepper.querySelectorAll(".phase-step.active")) {
    step.classList.remove("active");
    step.classList.add("error");
  }
}

function showStepper(visible) {
  phaseStepper.hidden = !visible;
}

// ---------- parsed spec card ----------

function renderParsedSpec(prompt, spec) {
  parsedSpecPrompt.textContent = `"${prompt}"`;
  parsedSpecGrid.innerHTML = "";
  const fields = [
    ["workload_type", spec.workload_type ?? "—"],
    ["target rows", numberFmt(spec.row_count)],
    ["mix_ratio", spec.mix_ratio !== undefined ? spec.mix_ratio.toFixed(2) : "—"],
    ["duration", `${spec.duration_seconds ?? "—"}s`],
    ["table", spec.table_name ?? "—"],
  ];
  for (const [label, value] of fields) {
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.textContent = String(value);
    parsedSpecGrid.appendChild(dt);
    parsedSpecGrid.appendChild(dd);
  }
}

// ---------- result rendering (post-complete) ----------

function renderRunFinal(record) {
  const spec = record.spec || {};
  const metrics = record.metrics || [];

  if (metrics.length > renderedSampleCount) {
    appendNewSamples(metrics);
    renderedSampleCount = metrics.length;
  }

  if (record.peak_acu !== undefined && record.peak_acu !== null) {
    tileAcuValue.textContent = record.peak_acu.toFixed(2);
    setAcuLevel(record.peak_acu);
  }

  metaEl.innerHTML = "";
  meta("Workload type", spec.workload_type ?? "—");
  meta("Target rows", numberFmt(spec.row_count));
  meta("Rows completed", numberFmt(record.rows_completed));
  meta("Selects completed", numberFmt(record.selects_completed));
  meta("Starting ACU", record.starting_acu?.toFixed(2) ?? "—");
  meta("Peak ACU", record.peak_acu?.toFixed(2) ?? "—");

  summaryEl.innerHTML = `<strong>Bedrock summary</strong>${escapeHtml(record.summary || "(no summary)")}`;
}

function renderClampBanner(spec) {
  if (spec.clamp_notes) {
    clampBanner.innerHTML = `
      <strong>Heads-up — your ask was clamped</strong>
      ${escapeHtml(spec.clamp_notes)}
      ${spec.original_prompt ? `<span class="original">You wrote: "${escapeHtml(spec.original_prompt)}"</span>` : ""}
    `;
    clampBanner.hidden = false;
  } else {
    clampBanner.hidden = true;
    clampBanner.innerHTML = "";
  }
}

function meta(label, value) {
  const div = document.createElement("div");
  div.innerHTML = `<span class="label">${escapeHtml(label)}</span><span class="value">${escapeHtml(String(value))}</span>`;
  metaEl.appendChild(div);
}

function showLiveTiles() {
  liveTiles.hidden = false;
}

function showResultSection() {
  resultSection.hidden = false;
}

// ---------- chart ----------

function initEmptyChart() {
  if (chart) {
    chart.destroy();
    chart = null;
  }
  chart = new Chart(chartCanvas, {
    type: "line",
    data: {
      labels: [],
      datasets: [
        {
          label: "Rows inserted",
          data: [],
          borderColor: "#1f6feb",
          backgroundColor: "rgba(31,111,235,0.15)",
          tension: 0.25,
          yAxisID: "y",
          fill: true,
        },
        {
          label: "ACU",
          data: [],
          borderColor: "#d97706",
          backgroundColor: "rgba(217,119,6,0.1)",
          borderDash: [4, 4],
          tension: 0.25,
          yAxisID: "y1",
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 250 },
      interaction: { mode: "index", intersect: false },
      stacked: false,
      scales: {
        y: {
          type: "linear",
          position: "left",
          title: { display: true, text: "Rows / second" },
          beginAtZero: true,
        },
        y1: {
          type: "linear",
          position: "right",
          title: { display: true, text: "ACU" },
          beginAtZero: true,
          grid: { drawOnChartArea: false },
        },
      },
    },
  });
}

// ---------- toast ----------

function showToast(message) {
  const el = document.createElement("div");
  el.className = "toast";
  el.textContent = message;
  toastContainer.appendChild(el);
  requestAnimationFrame(() => el.classList.add("show"));
  setTimeout(() => {
    el.classList.remove("show");
    setTimeout(() => el.remove(), 350);
  }, 5000);
}

// ---------- recent runs ----------

refreshRunsBtn.addEventListener("click", loadRecent);
window.addEventListener("DOMContentLoaded", loadRecent);

async function loadRecent() {
  try {
    const data = await api("GET", "/workloads");
    recentList.innerHTML = "";
    const runs = data.runs || [];
    if (!runs.length) {
      const li = document.createElement("li");
      li.textContent = "No completed runs yet.";
      recentList.appendChild(li);
      return;
    }
    for (const run of runs) {
      const li = document.createElement("li");
      li.innerHTML = `
        <span>${escapeHtml(run.run_id.slice(0, 8))}…</span>
        <span class="meta-cell">${escapeHtml(run.spec?.workload_type ?? "—")} · ${numberFmt(run.rows_completed)} rows · ACU ${run.starting_acu?.toFixed(1)}→${run.peak_acu?.toFixed(1)}</span>
        <span class="meta-cell">${escapeHtml(timeAgo(run.created_at))}</span>
      `;
      recentList.appendChild(li);
    }
  } catch (err) {
    recentList.innerHTML = `<li>${escapeHtml(err.message)}</li>`;
  }
}

// ---------- helpers ----------

function resetRunState() {
  renderedSampleCount = 0;
  scaleToastShown = false;
  runStartingAcu = null;
  resultSection.hidden = true;
  clampBanner.hidden = true;
  parsedSpecCard.hidden = true;
  liveTiles.hidden = true;
  tileRpsValue.textContent = "—";
  tileAcuValue.textContent = "—";
  tileAcu.classList.remove("acu-low", "acu-mid", "acu-high");
  tileElapsedValue.textContent = "0s";
}

function setStatus(kind, message) {
  statusEl.textContent = message;
  statusEl.className = `status ${kind}`;
}

async function api(method, path, body) {
  if (!apiUrl) {
    throw new Error("API URL not configured. Did config.js load?");
  }
  const opts = {
    method,
    headers: { "content-type": "application/json" },
  };
  if (body !== undefined) opts.body = JSON.stringify(body);

  const response = await fetch(`${apiUrl}${path}`, opts);
  let data = null;
  try {
    data = await response.json();
  } catch (_e) {
    data = null;
  }
  if (!response.ok) {
    const message = (data && (data.detail?.error || data.error)) || `HTTP ${response.status}`;
    const err = new Error(message);
    err.payload = data;
    throw err;
  }
  return data;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function elapsedSec(startedAt) {
  return Math.round((Date.now() - startedAt) / 1000);
}

function numberFmt(n) {
  if (n === undefined || n === null) return "—";
  return n.toLocaleString();
}

function timeAgo(iso) {
  if (!iso) return "";
  const delta = (Date.now() - new Date(iso).getTime()) / 1000;
  if (delta < 60) return `${Math.floor(delta)}s ago`;
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  return `${Math.floor(delta / 3600)}h ago`;
}

function escapeHtml(s) {
  return String(s).replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}
