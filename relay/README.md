# ccnotify relay

Lets a paired phone reach its PC when it is not on the PC's network and the
PC cannot be reached from the internet (most home connections: the provider
shares one public address between many customers).

The daemon and the phone both connect *out* to the relay, and it passes bytes
between them. Those bytes are the phone's usual connection to the daemon —
TLS with the PC's pinned certificate, then the device token — so the relay
cannot read or change anything, and needs no accounts of its own. See
`PROTOCOL.md` ("v1.4").

## On Cloudflare (free plan)

Needs a Cloudflare account and Node.js.

```sh
cd relay
npx wrangler login      # opens the browser once
npx wrangler deploy     # prints https://ccnotify-relay.<you>.workers.dev
```

Then, on the PC:

```sh
ccnotify relay wss://ccnotify-relay.<you>.workers.dev
ccnotify status         # "Relay: … (connected)"
```

Open the app on the phone once while it is on the PC's network: it learns the
relay from the PC. From then on it uses the local network at home and the
relay elsewhere. `ccnotify relay off` stops using it.

## On a machine of your own

```sh
ccnotify relay-server 8787
```

It speaks plain `ws://`: put a TLS proxy (Caddy, nginx) in front of it and
give the PC the `wss://` address.

## Notes

- A PC is known to the relay by its `pc_id`. The first daemon that connects
  for an id sets a key (kept in the PC's `config.json`); nobody else can take
  that id afterwards.
- Anyone who knows a `pc_id` can open a connection through the relay, exactly
  as anyone on your Wi-Fi can connect to the daemon's port. Without a paired
  phone's token they get nothing.
