# Keyfleet CLI

The command-line workspace for this product. It is a pnpm workspace with one
package, `@keyfleet/cli`, which publishes the `keyfleet` command.
Today that command only prints its usage and version: add product commands to
`packages/keyfleet-cli/src/` as the product grows.

With Node 22+ and the package manager version declared in `package.json`:

```sh
cd cli
pnpm install --frozen-lockfile
pnpm build
node packages/keyfleet-cli/dist/index.js --help
```

`make check-cli` from the monorepo root runs the build, typecheck and tests.
