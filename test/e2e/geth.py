"""Serves <upstream>'s JSON-RPC at 127.0.0.1:<port>, answering web3_clientVersion as Geth: an Anvil that
both the runner and forge, which the units ask in process, take for a live node."""

import http.server
import json
import sys
import urllib.request

port, upstream = int(sys.argv[1]), sys.argv[2]


class Proxy(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        call = json.loads(body)
        if isinstance(call, dict) and call.get("method") == "web3_clientVersion":
            data = json.dumps({"jsonrpc": "2.0", "id": call["id"], "result": "Geth/stub"}).encode()
        else:
            request = urllib.request.Request(upstream, body, {"Content-Type": "application/json"})
            data = urllib.request.urlopen(request).read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Proxy).serve_forever()
