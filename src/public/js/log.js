var l = "";
var c = "";
function ohc() {
  l = c;
  c = document.location.hash.slice(1);
  if (l!="") {
    var e = document.getElementById("M"+l);
    if (e != null) {
      e.classList.remove("selected");
    }
  }
  if (c!=l) {
    var e = document.getElementById("M"+c);
    if (e != null) {
      document.getElementById("M"+c).classList.add("selected");
    }
  }
}
window.onload = ohc;
window.onhashchange = ohc;
