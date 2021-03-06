var scrolledToNearlyBottom = function() {
  // https://gist.github.com/nathansmith/8939548
  var totalHeight = document.body.offsetHeight;
  var viewportBottom = window.scrollY + window.innerHeight;
  return viewportBottom >= totalHeight - 20;
};

var scrollToBottom = function() {
  var scrollingElement = document.scrollingElement || document.body;
  scrollingElement.scrollTop = scrollingElement.scrollHeight;
};

var loginRedirectIfNecessary = function(entry) {
  if (entry.needs_login) {
    window.location.replace("login");
  }
};

var extractEntry = function(event) {
  return JSON.parse(decodeURIComponent(event.data));
};

var addLogEntry = function(event) {
  var shouldUpdateScrollPosition = scrolledToNearlyBottom();
  var entry = extractEntry(event);

  var tbody = document.getElementById("log-entries");
  tbody.insertAdjacentHTML("beforeend", entry.html);

  loginRedirectIfNecessary(entry);
  if (shouldUpdateScrollPosition) {
    scrollToBottom();
  }
};

var replaceLogEntry = function(event) {
  var tr = document.getElementById("id-" + event.lastEventId);
  
  var entry = extractEntry(event);

  if (tr) {
    // If the log entry was already marked as complete, there's nothing to do.
    if (tr.dataset.complete == "true") {
      return;
    }

    var shouldUpdateScrollPosition = scrolledToNearlyBottom();

    tr.outerHTML = entry.html;
    if (shouldUpdateScrollPosition) {
      scrollToBottom();
    }
  } else {
    // if there's nothing to replace add instead
    addLogEntry(event);
  }

  loginRedirectIfNecessary(entry);
};

var onProcessStart = function() {
  document.getElementById("running-indicator-inactive").classList.add("d-none");
  document.getElementById("running-indicator-active").classList.remove("d-none");
};

var onProcessExit = function() {
  document.getElementById("running-indicator-inactive").classList.remove("d-none");
  document.getElementById("running-indicator-active").classList.add("d-none");
};

var updateRunningIndicator = function() {
  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
    if (this.readyState === XMLHttpRequest.DONE && this.status == 200) {
      if (this.responseText === "true") {
        onProcessStart();
      } else {
        onProcessExit();
      }
    }
  };
  xhttp.open("GET", "running", true);
  xhttp.send(); 
};

var onDocumentReady = function() {
  // Register server side event (SSE) listeners
  var src = new EventSource("/log");
  src.addEventListener("start", onProcessStart);
  src.addEventListener("exit", onProcessExit);
  src.addEventListener("add", addLogEntry);
  src.addEventListener("replace", replaceLogEntry);

  // The process might have died _after_ the HTML was rendered on the server
  // and _before_ the SSE listener is connected. In this case the running
  // indicator would be wrong. The `start` and `exit` events are also not
  // part of the log so later requests to `/log` (see above) won't fix it.
  updateRunningIndicator();

  // Start at the bottom, that's where the interesting, already statically rendered log entries are
  scrollToBottom();
};

if (document.readyState !== "loading") {
  onDocumentReady();
} else {
  document.addEventListener("DOMContentLoaded", onDocumentReady);
}
