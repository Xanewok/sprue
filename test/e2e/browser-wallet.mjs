// A stand-in for a browser wallet on forge's --browser page: it connects as <address>, sends each
// requested transaction through the node, which must have <address> unlocked, and answers with the hash.
// Each forge process serves a page of its own, so it connects again whenever the page comes back.
// Mode `own-nonce` acts as a wallet that picks its own nonce: before its first send it sends a
// transaction of its own, and it drops the nonce that forge asks for.
// usage: node browser-wallet.mjs <port> <rpc> <address> [exact|own-nonce]
const [port, rpc, address, mode = "exact"] = process.argv.slice(2);
const page = `http://127.0.0.1:${port}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const node = async (method, params) => {
  const r = await (await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) })).json();
  if (r.error) throw new Error(r.error.message);
  return r.result;
};
let bumped = false;
for (;;) {
  let token;
  try {
    token = /__SESSION_TOKEN__ = "([^"]+)"/.exec(await (await fetch(`${page}/main.js`)).text())?.[1];
  } catch {}
  if (!token) { await sleep(100); continue; }
  const api = async (path, body) => {
    const r = await fetch(`${page}/api${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers: { "content-type": "application/json", "X-Session-Token": token },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return r.json();
  };
  try {
    const chainId = Number(await node("eth_chainId", []));
    await api("/connection", { address, chainId });
    console.error(`wallet: connected as ${address} on chain ${chainId}`);
    for (;;) {
      const sw = await api("/chain/request");
      if (sw.status === "ok" && sw.data) await api("/chain/response", { id: sw.data.id, chainId });
      const t = await api("/transaction/request");
      if (t.status === "ok" && t.data) {
        const tx = { ...t.data.request };
        if (mode === "own-nonce") {
          if (!bumped) { await node("eth_sendTransaction", [{ from: address, to: address }]); bumped = true; }
          delete tx.nonce;
        }
        try {
          const hash = await node("eth_sendTransaction", [tx]);
          console.error(`wallet: sent ${hash}`);
          await api("/transaction/response", { id: t.data.id, hash });
        } catch (e) {
          await api("/transaction/response", { id: t.data.id, error: e.message });
        }
      }
      await sleep(100);
    }
  } catch {
    // The page is gone: its forge exited.
    await sleep(100);
  }
}
