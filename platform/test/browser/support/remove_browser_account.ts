import {execFileSync} from "node:child_process"

// Specs sign in as the account `Keyfleet.TestPrivyVerifier` vouches for, and the
// server commits it with a sign-in record per session. Removing it after the run
// leaves the partition database with only the catalog the server started with.
export default function removeBrowserAccount() {
  execFileSync(
    "mix",
    ["run", "-e", 'Keyfleet.CommittedAccount.remove!("did:privy:verified")'],
    {env: {...process.env, MIX_ENV: "test"}, stdio: "inherit"},
  )
}
