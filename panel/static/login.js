/* Decolab panel - login page: show the hint after a wrong token. */
(function () {
  if (new URLSearchParams(location.search).has('wrong')) {
    document.getElementById('wrong').hidden = false;
    history.replaceState(null, '', '/');
  }
  document.getElementById('token').focus();
})();
