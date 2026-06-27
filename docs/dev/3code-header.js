// 3code doc header — logo + Documentation links above h1.title
(function() {
  var path = window.location.pathname;
  var inSub = /\/docs\/[^/]+\/[^/]+\.html/.test(path);
  var siteRoot = inSub ? '../../' : '../';
  var docsRoot = inSub ? '../' : '';

  document.addEventListener('DOMContentLoaded', function() {
    var title = document.querySelector('h1.title');
    if (!title) return;

    var wrap = document.createElement('div');
    wrap.className = 'doc-site-header';

    var logo = document.createElement('a');
    logo.href = siteRoot;
    logo.className = 'doc-site-logo';
    logo.textContent = '3code';

    var sep = document.createTextNode(' ');

    var docLink = document.createElement('a');
    docLink.href = docsRoot + 'manual.html';
    docLink.className = 'doc-site-doclink';
    docLink.textContent = 'Documentation';

    wrap.appendChild(logo);
    wrap.appendChild(sep);
    wrap.appendChild(docLink);
    title.parentNode.insertBefore(wrap, title);
  });
})();
