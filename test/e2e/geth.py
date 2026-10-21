"""Serves <upstream>'s JSON-RPC at 127.0.0.1:<port>, answering web3_clientVersion as Geth: an Anvil that
both the runner and forge, which the units ask in process, take for a live node. With $LAG it answers
reads of the head as that many blocks behind, as a load-balanced endpoint that asks a lagging node;
receipts and sends still reach the upstream's head."""

import http.server
import json
import os
import sys
import urllib.request

port, upstream = int(sys.argv[1]), sys.argv[2]
lag = int(os.environ.get("LAG", "0"))


def ask(body):
    request = urllib.request.Request(upstream, body, {"Content-Type": "application/json"})
    return urllib.request.urlopen(request).read()


class Proxy(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        call = json.loads(body)
        if isinstance(call, dict) and call.get("method") == "web3_clientVersion":
            data = json.dumps({"jsonrpc": "2.0", "id": call["id"], "result": "Geth/stub"}).encode()
        elif lag:
            head = int(json.loads(ask(b'{"jsonrpc":"2.0","id":0,"method":"eth_blockNumber","params":[]}'))["result"], 16)
            head = hex(max(0, head - lag))
            replies = []
            for c in call if isinstance(call, list) else [call]:
                if c.get("method") == "eth_blockNumber":
                    replies.append({"jsonrpc": "2.0", "id": c.get("id"), "result": head})
                else:
                    c["params"] = [head if p == "latest" else p for p in c.get("params") or []]
                    replies.append(json.loads(ask(json.dumps(c).encode())))
            data = json.dumps(replies if isinstance(call, list) else replies[0]).encode()
        else:
            data = ask(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Proxy).serve_forever()
