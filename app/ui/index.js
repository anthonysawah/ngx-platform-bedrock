/* eslint-env browser */

const apiUrl = (window.NGX_API_URL || "").replace(/\/$/, "");

const form = document.getElementById("prompt-form");
const promptInput = document.getElementById("prompt");
const submitBtn = document.getElementById("submit-btn");
const statusEl = document.getElementById("status");
const resultSection = document.getElementById("result");
const clampBanner = document.getElementById("clamp-banner");
const metaEl = document.getElementById("meta");
const summaryEl = document.getElementById("summary");
const chartCanvas = document.getElementById("chart");
const recentList = document.getElementById("recent-runs");
const refreshRunsBtn = document.getElementById("refresh-runs-btn");

let chart = null;

const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 240_000; // 4 minutes — schema caps duration at 180s
const TERMINAL_STATUSES = new Set([
  "complete",
  "bedrock_error",
  "workload_error",
  "timeout",
]);

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const prompt = promptInput.value.trim();
  if (!prompt) return;

  setStatus("running", "Parsing intent…");
  submitBtn.disabled = true;
  resultSection.hidden = true;

  try {
    const created = await api("POST", "/workloads", { prompt });
    const runId = created.run_id;
    const startedAt = Date.now();

    setStatus(
      "running",
      `Run ${runId.slice(0, 8)}… running (target ${created.spec?.duration_seconds ?? "?"}s).`,
    );

    const final = await pollUntilTerminal(runId, startedAt);
    if (final.status === "complete") {
      renderRun(final);
      setStatus("complete", `Run ${runId.slice(0, 8)}… complete in ${elapsedSec(startedAt)}s.`);
      loadRecent();
    } else {
      const reason = final.error || `status ${final.status}`;
      setStatus("error", `Run ended: ${reason}`);
    }
  } catch (err) {
    setStatus("error", err.message);
  } finally {
    submitBtn.disabled = false;
  }
});

async function pollUntilTerminal(runId, startedAt) {
  while (Date.now() - startedAt < POLL_TIMEOUT_MS) {
    await sleep(POLL_INTERVAL_MS);
    const record = await api("GET", `/workloads/${runId}`);
    if (TERMINAL_STATUSES.has(record.status)) {
      return record;
    }
    setStatus(
      "running",
      `Run ${runId.slice(0, 8)}… ${record.status} · ${elapsedSec(startedAt)}s elapsed · ${(record.metrics?.length ?? 0)} samples`,
    );
  }
  throw new Error("Polling timed out before run completed.");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function elapsedSec(startedAt) {
  return Math.round((Date.now() - startedAt) / 1000);
}

refreshRunsBtn.addEventListener("click", loadRecent);

window.addEventListener("DOMContentLoaded", loadRecent);

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

function renderRun(record) {
  const spec = record.spec || {};
  const metrics = record.metrics || [];

  // Honest-clamp banner: if Bedrock clamped any field, surface it
  // verbatim above the chart along with the user's original prompt.
  // ADR-011 — never silently mutate user input.
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

  metaEl.innerHTML = "";
  meta("Workload type", spec.workload_type ?? "—");
  meta("Target rows", numberFmt(spec.row_count));
  meta("Mix ratio", spec.mix_ratio !== undefined ? spec.mix_ratio.toFixed(2) : "—");
  meta("Duration target", `${spec.duration_seconds ?? "—"}s`);
  meta("Rows completed", numberFmt(record.rows_completed));
  meta("Selects completed", numberFmt(record.selects_completed));
  meta("Starting ACU", record.starting_acu?.toFixed(2) ?? "—");
  meta("Peak ACU", record.peak_acu?.toFixed(2) ?? "—");

  drawChart(metrics);

  summaryEl.innerHTML = `<strong>Bedrock summary</strong>${escapeHtml(record.summary || "(no summary)")}`;
  resultSection.hidden = false;
}

function meta(label, value) {
  const div = document.createElement("div");
  div.innerHTML = `<span class="label">${escapeHtml(label)}</span><span class="value">${escapeHtml(String(value))}</span>`;
  metaEl.appendChild(div);
}

function drawChart(metrics) {
  if (chart) {
    chart.destroy();
    chart = null;
  }
  if (!metrics.length) return;

  const labels = metrics.map((m) => `t+${m.second_offset}s`);
  const rowsPerSecond = metrics.map((m) => m.rows_inserted);
  const acuValues = metrics.map((m) => m.current_acu);

  chart = new Chart(chartCanvas, {
    type: "line",
    data: {
      labels,
      datasets: [
        {
          label: "Rows inserted",
          data: rowsPerSecond,
          borderColor: "#1f6feb",
          backgroundColor: "rgba(31,111,235,0.15)",
          tension: 0.25,
          yAxisID: "y",
          fill: true,
        },
        {
          label: "ACU",
          data: acuValues,
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
