// Local stand-in for Keyfleet's /.well-known/hub-jwks.json: serves the public
// key that local/drive.mjs signs passes with, over HTTPS with a certificate made
// for this run, as the hub only reads its keys from an HTTPS address. Runs inside
// a container on the hub's network; local proof only.
import { readFileSync } from 'node:fs';
import https from 'node:https';

const keys = readFileSync('/jwks/jwks.json');

https
	.createServer(
		{ key: readFileSync('/jwks/tls.key'), cert: readFileSync('/jwks/tls.crt') },
		(request, response) => {
			if (request.method === 'GET' && request.url === '/jwks.json') {
				response.writeHead(200, { 'content-type': 'application/json' }).end(keys);
			} else {
				response.writeHead(404).end();
			}
		},
	)
	.listen(8443);
