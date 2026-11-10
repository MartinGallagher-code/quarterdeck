# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""One request to a test's qd web: tests/test_web.sh's req.

    web_req.py BASE PATH [HEADER:VALUE...]

Prints the status, then the Location and Set-Cookie headers when there are
any, then the body.  Never follows a redirect.  0.0.0.0 in BASE is reached
as 127.0.0.1; https is verified against the cert named by $QD_TEST_CA.
"""

import os
import ssl
import sys
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def main(argv):
    base = argv[1].replace("0.0.0.0", "127.0.0.1")
    path, hdrs = argv[2], argv[3:]
    handlers = [NoRedirect()]
    if base.startswith("https"):
        ctx = ssl.create_default_context(cafile=os.environ["QD_TEST_CA"])
        ctx.check_hostname = False
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    opener = urllib.request.build_opener(*handlers)
    r = urllib.request.Request(base.rstrip("/") + path,
                               headers=dict(h.split(":", 1) for h in hdrs))
    try:
        resp = opener.open(r, timeout=20)
        status, head, body = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        status, head, body = e.code, e.headers, e.read()
    out = b"%d\n" % status
    for k in ("Location", "Set-Cookie"):
        if head.get(k):
            out += ("%s: %s\n" % (k, head.get(k))).encode("utf-8")
    # bytes: under LANG=C a 3.6 stdout is ASCII
    sys.stdout.buffer.write(out + body + b"\n")


if __name__ == "__main__":
    main(sys.argv)
