var loginRedirectIfNecessary = function(entry) {
  if (entry.needs_login) {
    window.location.replace("login");
  }
};

var extractEntry = function(event) {
  return JSON.parse(decodeURIComponent(event.data));
};

var addLogEntry = function(event) {
  var entry = extractEntry(event);

  var tbody = document.getElementById("log-entries");
  tbody.insertAdjacentHTML("beforeend", entry.html);

  loginRedirectIfNecessary(entry);
};

var replaceLogEntry = function(event) {
  var entry = extractEntry(event);

  var tr = document.getElementById(event.lastEventId);
  if (tr) {
    tr.outerHTML = entry.html;
  } else {
    // if there's nothing to replace add instead
    addLogEntry(event);
  }

  loginRedirectIfNecessary(entry);
};

var onDocumentReady = function() {
  // register server side event (SSE) listeners
  var src = new EventSource("/log");
  src.addEventListener("add", addLogEntry);
  src.addEventListener("replace", replaceLogEntry);
};

if (document.readyState !== "loading") {
  onDocumentReady();
} else {
  document.addEventListener("DOMContentLoaded", onDocumentReady);
}
