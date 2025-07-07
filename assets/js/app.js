

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken }
})

function getQueryParam(param) {
  const urlParams = new URLSearchParams(window.location.search);
  return urlParams.get(param);
}

let socket = new Socket("/socket", {
  params: {
    roleName: getQueryParam("role"),           // e.g. "expert" or "viewer"
    matchIdArray: getQueryParam("matchId") || "f38439f3-6a44-4f7a-a784-83424ac9e042", // e.g. "m1,m2,m3" or a single match ID
    userId:getQueryParam("userId")    // comma-separated, e.g. "m1,m2,m3"
  }
});
socket.connect();
let channel = socket.channel("matches:lobby", {});

// When the client successfully joins, the server will subscribe it to
// all relevant subtopics and begin pushing “match_data” messages.
channel.join()
  .receive("ok", _resp => {
    console.log("Joined matches:lobby, now listening for data…");
  })
  .receive("error", resp => {
    console.error("Failed to join:", resp);
  });

// Whenever any of the subtopics emit {:match_data, …}, your channel’s handle_info
// will push a "match_data" event to the client:
channel.on("match_data", payload => {
  // Example payload: { "match_id": "m1", "score": "2-1", "ts": "2025-06-04T…Z" }
  console.log("Received live update:", payload);
  // Update your UI accordingly.
});

// If at some point you want to stop receiving *one* match’s updates:
function leaveCricketForMatch(matchId) {
  channel.push("disconnectCricketData", {
    matchId: matchId,
    roleName: window.roleName
  });
}

// If you want to leave *all* matches at once:
function leaveAllMatches() {
  channel.push("leaveAllRoom", {});
}
// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

import "./hooks"

