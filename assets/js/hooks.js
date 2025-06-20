import { Presence, Socket } from "phoenix";
import "phoenix_html";

let previousData = null;
let presences = {};

// ───────────────────────────────────────────────────────────
// DOM Helpers
// ───────────────────────────────────────────────────────────
const oddsBody = () => document.getElementById("odds-body");
const presenceList = () => document.getElementById("presence-list");

function getQueryParam(param) {
  const urlParams = new URLSearchParams(window.location.search);
  return urlParams.get(param);
}
function formatTimestamp(seconds) {
  const date = new Date(seconds * 1000); // Convert to ms
  return date.toLocaleString(); // or use toLocaleTimeString() for just time
}
// ───────────────────────────────────────────────────────────
// Render Presence UI
// ───────────────────────────────────────────────────────────
function renderPresences(presences) {
  const ul = presenceList();
  if (!ul) return;

  ul.innerHTML = Presence.list(presences, (_id, { metas }) => {
    const [firstMeta] = metas;
    return `<li>${firstMeta.role || "anonymous"} - online since ${formatTimestamp(firstMeta.online_at)}</li>`;
  }).join("");
}

// ───────────────────────────────────────────────────────────
// Render Tournament Data
// ───────────────────────────────────────────────────────────
function renderData(data) {
  const tbody = oddsBody();
  if (!tbody) return;

  tbody.innerHTML = ""; // clear old data

  data.tournament?.reverse().forEach((tourney, tIdx) => {
    const headerRow = document.createElement("tr");
    const headerCell = document.createElement("td");
    headerCell.setAttribute("colspan", "7");
    headerCell.textContent = `Tournament: ${tourney.name || tourney.id}`;
    headerCell.classList.add("tourney-header");
    headerRow.appendChild(headerCell);
    tbody.appendChild(headerRow);

    tourney.runners.forEach((runner, rIdx) => {
      const row = document.createElement("tr");
      row.classList.add("team-row");

      const teamCell = document.createElement("td");
      teamCell.classList.add("team-cell");
      teamCell.textContent = runner.nat;
      row.appendChild(teamCell);

      runner?.ex?.availableToBack?.forEach((entry, lvl) => {
        const priceTd = document.createElement("td");
        priceTd.classList.add(["back1", "back2", "back3"][lvl]);
        priceTd.id = `cell-back-price-${tIdx}-${rIdx}-${lvl}`;
        priceTd.innerHTML = `${entry.price.toFixed(2)} <br/> ${entry.size.toFixed(2)}`;
        row.appendChild(priceTd);
      });

      runner?.ex?.availableToLay?.forEach((entry, lvl) => {
        const priceTd = document.createElement("td");
        priceTd.classList.add(["lay1", "lay2", "lay3"][lvl]);
        priceTd.id = `cell-lay-price-${tIdx}-${rIdx}-${lvl}`;
        priceTd.innerHTML = `${entry.price.toFixed(2)} <br/> ${entry.size.toFixed(2)}`;
        row.appendChild(priceTd);
      });

      tbody.appendChild(row);
    });
  });

  previousData = JSON.parse(JSON.stringify(data)); // deep copy
}

function updateData(newData) {
  if (!previousData) {
    renderData(newData);
    return;
  }

  newData.tournament.reverse().forEach((newTourney, tIdx) => {
    const prevTourney = previousData.tournament[tIdx];
    if (!prevTourney) return renderData(newData);

    newTourney.runners.forEach((newRunner, rIdx) => {
      const prevRunner = prevTourney.runners[rIdx];
      if (!prevRunner) return renderData(newData);

      newRunner?.ex?.availableToBack?.forEach((newEntry, lvl) => {
        const prevEntry = prevRunner.ex.availableToBack[lvl];
        const cellId = `cell-back-price-${tIdx}-${rIdx}-${lvl}`;
        const td = document.getElementById(cellId);
        if (!td) return;
        if (newEntry.price !== prevEntry.price) {
          td.innerHTML = `${newEntry.price.toFixed(2)} <br/> ${newEntry.size.toFixed(2)}`;
          flashCell(td);
        }
      });

      newRunner?.ex?.availableToLay?.forEach((newEntry, lvl) => {
        const prevEntry = prevRunner.ex.availableToLay[lvl];
        const cellId = `cell-lay-price-${tIdx}-${rIdx}-${lvl}`;
        const td = document.getElementById(cellId);
        if (!td) return;
        if (newEntry.price !== prevEntry.price) {
          td.innerHTML = `${newEntry.price.toFixed(2)} <br/> ${newEntry.size.toFixed(2)}`;
          flashCell(td);
        }
      });
    });
  });

  previousData = JSON.parse(JSON.stringify(newData));
}

// ───────────────────────────────────────────────────────────
// Cell Flashing
// ───────────────────────────────────────────────────────────
function flashCell(cell) {
  cell.classList.add("changed");
  setTimeout(() => cell.classList.remove("changed"), 1000);
}

// ───────────────────────────────────────────────────────────
// Phoenix Socket Setup
// ───────────────────────────────────────────────────────────
let socket = new Socket("/socket", {
  params: {
    roleName: getQueryParam("role"),
    matchIdArray: getQueryParam("matchId") || "f38439f3-6a44-4f7a-a784-83424ac9e042",
    user_id: getQueryParam("userId")
  }
});

socket.connect();
let channel = socket.channel("matches:lobby", {});
let hasRenderedOnce = false;

channel.join()
  .receive("ok", (_resp) => {
    console.log("Joined matches:lobby!");
  })
  .receive("error", (resp) => {
    console.error("Failed to join:", resp);
  });

channel.on("match_data", (payload) => {
  if (!hasRenderedOnce) {
    renderData(payload);
    hasRenderedOnce = true;
  } else {
    updateData(payload);
  }
});

// ───────────────────────────────────────────────────────────
// Presence Events
// ───────────────────────────────────────────────────────────
channel.on("presence_state", (state) => {
  presences = Presence.syncState(presences, state);
  renderPresences(presences);
});

channel.on("presence_diff", (diff) => {
  presences = Presence.syncDiff(presences, diff);
  renderPresences(presences);
});
