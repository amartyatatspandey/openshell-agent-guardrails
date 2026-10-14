#!/usr/bin/env python3
"""A fake MCP server for the Kyverno bonus: JSON-RPC 2.0 over HTTP POST /mcp.

Every tool returns canned text; nothing is read, written, or deleted. Each
request that reaches this server is logged as "MCP-SERVER served <method>
<tool>", so the bonus can show which calls Kyverno let through and that the
denied ones never arrived. Listens on 127.0.0.1 only; the sandbox reaches it as
host.openshell.internal through the OpenShell proxy.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS = [
    {"name": "search_issues", "description": "Search issues in a repository (fake data).",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}}},
    {"name": "read_file", "description": "Read a file from the project workspace (fake data).",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "delete_repo", "description": "Delete a repository (fake: does nothing).",
     "inputSchema": {"type": "object", "properties": {"repo": {"type": "string"}}}},
]


def log(msg):
    print(msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ok": True})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/mcp":
            self.reply(404, {"error": "not found"})
            return
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, TypeError):
            self.reply(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            return
        rid, method = req.get("id"), req.get("method")
        params = req.get("params") or {}
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "fake-mcp", "version": "0.1.0"}}
            log("MCP-SERVER served initialize")
        elif method == "tools/list":
            result = {"tools": TOOLS}
            log("MCP-SERVER served tools/list")
        elif method == "tools/call":
            name = params.get("name")
            if name not in {t["name"] for t in TOOLS}:
                self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "unknown tool"}})
                return
            result = {"content": [{"type": "text", "text": f"fake result from {name}"}], "isError": False}
            log(f"MCP-SERVER served tools/call {name} arguments={json.dumps(params.get('arguments', {}))}")
        else:
            self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})
            return
        self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": result})


def main():
    port = int(os.environ.get("MCP_PORT", "8766"))
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log(f"MCP-SERVER listening on 127.0.0.1:{port}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
